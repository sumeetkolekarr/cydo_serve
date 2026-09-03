-- ============================================================
-- CyberDojo Backend — Complete Database Schema (PostgreSQL)
-- ============================================================
-- This file is idempotent-ish: CREATE TABLE statements will error
-- on existing tables (run them piecemeal on an existing DB), but
-- ALTER ... ADD COLUMN IF NOT EXISTS is safe.

-- ------------------------------------------------------------
-- USER-FACING TABLES (existing)
-- ------------------------------------------------------------

-- 1. Users
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    full_name VARCHAR(150),
    hashed_password VARCHAR(255) NOT NULL,
    newsletter_opt_in BOOLEAN DEFAULT FALSE,
    terms_agreed BOOLEAN DEFAULT FALSE,
    available_credits INTEGER DEFAULT 0,
    referral_code VARCHAR(20) UNIQUE,
    is_active BOOLEAN DEFAULT TRUE,            -- added for admin ban support
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;

-- 2. Subscriptions
CREATE TABLE IF NOT EXISTS subscriptions (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    plan_name VARCHAR(50) NOT NULL,
    billing_cycle VARCHAR(20) NOT NULL,
    start_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    end_date TIMESTAMP NOT NULL,
    is_active BOOLEAN DEFAULT TRUE
);

-- 3. Credit Transactions
CREATE TABLE IF NOT EXISTS credit_transactions (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    plan_name VARCHAR(50),
    credits_added INTEGER NOT NULL,
    amount_paid DECIMAL(10, 2) NOT NULL,
    purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Contact Messages
CREATE TABLE IF NOT EXISTS contact_messages (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    status VARCHAR(50) DEFAULT 'unread',       -- unread | read | replied | dismissed
    admin_note TEXT,                            -- added for admin triage
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE contact_messages ADD COLUMN IF NOT EXISTS admin_note TEXT;
CREATE INDEX IF NOT EXISTS idx_contacts_status ON contact_messages(status);

-- 5. Referrals
CREATE TABLE IF NOT EXISTS referrals (
    id SERIAL PRIMARY KEY,
    referrer_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    referred_user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    reward_credits INTEGER DEFAULT 10,
    status VARCHAR(50) DEFAULT 'completed',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 6. User Progress
CREATE TABLE IF NOT EXISTS user_progress (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    course_name VARCHAR(255) NOT NULL,
    module_name VARCHAR(255) NOT NULL,
    is_completed BOOLEAN DEFAULT TRUE,
    completed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, course_name, module_name)
);

-- ------------------------------------------------------------
-- ADMIN PANEL TABLES (new)
-- ------------------------------------------------------------

-- 7. Admins (completely separate from users)
CREATE TABLE IF NOT EXISTS admins (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    hashed_password VARCHAR(255) NOT NULL,
    full_name VARCHAR(255),
    role VARCHAR(20) DEFAULT 'admin',          -- 'admin' | 'superadmin'
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login_at TIMESTAMP NULL,
    CHECK (role IN ('admin', 'superadmin'))
);
CREATE INDEX IF NOT EXISTS idx_admins_email ON admins(email);

-- 8. Admin audit log
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id SERIAL PRIMARY KEY,
    admin_id INTEGER REFERENCES admins(id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL,               -- create | update | delete | credit_adjust | status_change
    entity_type VARCHAR(50) NOT NULL,          -- lab | user | contact | admin
    entity_id VARCHAR(100),
    before_payload JSONB,
    after_payload JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_admin ON admin_audit_log(admin_id);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON admin_audit_log(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON admin_audit_log(created_at);

-- 9. Lab catalog (populated via admin UI in Part 2 prep)
CREATE TABLE IF NOT EXISTS lab_catalog (
    lab_id VARCHAR(100) PRIMARY KEY,
    slug VARCHAR(100) NOT NULL,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    difficulty VARCHAR(20) DEFAULT 'Medium',   -- Easy | Medium | Hard
    credits_cost INTEGER NOT NULL DEFAULT 1,
    duration_minutes INTEGER NOT NULL DEFAULT 60,
    os_type VARCHAR(20) NOT NULL DEFAULT 'linux',  -- windows | linux | mixed
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CHECK (difficulty IN ('Easy', 'Medium', 'Hard')),
    CHECK (os_type IN ('windows', 'linux', 'mixed'))
);
CREATE INDEX IF NOT EXISTS idx_labs_category ON lab_catalog(category);
CREATE INDEX IF NOT EXISTS idx_labs_active ON lab_catalog(is_active);

-- Auto-update lab_catalog.updated_at on row change
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS lab_catalog_set_updated_at ON lab_catalog;
CREATE TRIGGER lab_catalog_set_updated_at
    BEFORE UPDATE ON lab_catalog
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ============================================================
-- LAB SESSIONS (Part 2)
-- ============================================================
CREATE TABLE IF NOT EXISTS end_lab_trial (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    lab_id VARCHAR(100) REFERENCES lab_catalog(lab_id),
    instance_ids TEXT NOT NULL,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    ends_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_end_lab_trial_user ON end_lab_trial(user_id);

-- ============================================================
-- RECURRING SUBSCRIPTIONS (Part 5)
-- ============================================================
-- Idempotent column additions for Razorpay Subscriptions API integration.
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS razorpay_subscription_id VARCHAR(64);
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS razorpay_customer_id VARCHAR(64);
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS auto_renew_status VARCHAR(20) DEFAULT 'manual';
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS next_charge_at TIMESTAMPTZ;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS current_period_end TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_subs_rzp_id ON subscriptions(razorpay_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subs_active_end ON subscriptions(is_active, end_date);

-- Webhook event log + idempotency guard.
-- Inserts use UNIQUE(razorpay_event_id) so duplicate webhook POSTs from Razorpay
-- safely error with IntegrityError, which the handler treats as a successful no-op.
CREATE TABLE IF NOT EXISTS subscription_events (
    id SERIAL PRIMARY KEY,
    razorpay_event_id VARCHAR(128) UNIQUE,
    razorpay_subscription_id VARCHAR(64),
    event_type VARCHAR(50) NOT NULL,
    payload JSONB,
    received_at TIMESTAMPTZ DEFAULT NOW(),
    processed BOOLEAN DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_sub_evt_sub ON subscription_events(razorpay_subscription_id);
CREATE INDEX IF NOT EXISTS idx_sub_evt_unprocessed ON subscription_events(processed) WHERE processed = FALSE;

-- ============================================================
-- CREDIT PACKS (Part 5)
-- ============================================================
-- DB-backed pack catalog so admins can edit prices/quantities from the panel
-- instead of editing the React source. Frontend GETs /api/credit-packs;
-- backend validates pack/price/credits on every /api/credits/create-order.
CREATE TABLE IF NOT EXISTS credit_packs (
    id SERIAL PRIMARY KEY,
    pack_name VARCHAR(50) UNIQUE NOT NULL,
    credits INTEGER NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    display_order INTEGER DEFAULT 0,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_credit_packs_active ON credit_packs(is_active, display_order);

-- Seed with current Credit.jsx hardcoded values. ON CONFLICT preserves admin edits on re-run.
INSERT INTO credit_packs (pack_name, credits, price, display_order, description) VALUES
    ('Basic',   25,  399, 1, 'Starter pack'),
    ('Pro',     50,  499, 2, 'Best value'),
    ('Premium', 100, 979, 3, 'For power users')
ON CONFLICT (pack_name) DO NOTHING;

-- Auto-update credit_packs.updated_at on row change (reuses trg_set_updated_at from lab_catalog).
DROP TRIGGER IF EXISTS credit_packs_set_updated_at ON credit_packs;
CREATE TRIGGER credit_packs_set_updated_at
    BEFORE UPDATE ON credit_packs
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ============================================================
-- COUPONS (Part 7)
-- ============================================================
-- Admin-created discount codes with percentage off. Applies to credit pack
-- purchases in v1; subscription redemption is a planned follow-up.
-- - max_uses NULL = unlimited; otherwise capped by uses_count.
-- - expires_at NULL = never expires.
-- - is_active toggle gives admin a non-destructive "disable" without
--   breaking the coupon_redemptions audit trail.
-- - Per-user single redemption is enforced via the coupon_redemptions
--   unique index further down.
CREATE TABLE IF NOT EXISTS coupons (
    id SERIAL PRIMARY KEY,
    code VARCHAR(50) UNIQUE NOT NULL,
    discount_percent INTEGER NOT NULL CHECK (discount_percent BETWEEN 1 AND 100),
    description TEXT,
    max_uses INTEGER,
    uses_count INTEGER NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_coupons_active_code ON coupons(is_active, code);

-- Redemption log: one row per successful coupon use. The unique constraint
-- on (coupon_id, user_id) is what enforces "each user can use a code once".
CREATE TABLE IF NOT EXISTS coupon_redemptions (
    id SERIAL PRIMARY KEY,
    coupon_id INTEGER NOT NULL REFERENCES coupons(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credit_transaction_id INTEGER REFERENCES credit_transactions(id) ON DELETE SET NULL,
    discount_amount NUMERIC(10, 2) NOT NULL,
    redeemed_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (coupon_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_coupon_redemptions_user ON coupon_redemptions(user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_redemptions_coupon ON coupon_redemptions(coupon_id);

-- Reuse the trg_set_updated_at trigger function from lab_catalog.
DROP TRIGGER IF EXISTS coupons_set_updated_at ON coupons;
CREATE TRIGGER coupons_set_updated_at
    BEFORE UPDATE ON coupons
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ============================================================
-- COURSE CATALOG (Part 8)
-- ============================================================
-- DB-backed catalog for the six public course pages. Replaces the hardcoded
-- courseInfo/syllabus constants in the .jsx files so admins edit content +
-- pricing from /admin/courses instead of touching React source. Public reads
-- via /api/courses; admin CRUD via /api/admin/courses. Soft-delete keeps
-- historical references in the audit log readable.
CREATE TABLE IF NOT EXISTS course_catalog (
    id              SERIAL PRIMARY KEY,
    slug            VARCHAR(50) UNIQUE NOT NULL,
    title           VARCHAR(200) NOT NULL,
    tagline         VARCHAR(300),
    description     TEXT,
    category        VARCHAR(50),
    difficulty      VARCHAR(20) CHECK (difficulty IN ('Beginner','Intermediate','Advanced')),
    modules_count   INTEGER,
    labs_count      INTEGER,
    duration_hours  INTEGER,
    price_inr       NUMERIC(10, 2),
    currency        VARCHAR(8)  DEFAULT 'INR',
    billing_label   VARCHAR(50),
    hero_image_url  TEXT,
    accent_color    VARCHAR(20) DEFAULT 'red',
    audience        JSONB NOT NULL DEFAULT '[]'::jsonb,
    benefits        JSONB NOT NULL DEFAULT '[]'::jsonb,
    syllabus        JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_active       BOOLEAN     DEFAULT TRUE,
    display_order   INTEGER     DEFAULT 0,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_course_catalog_active_order ON course_catalog(is_active, display_order);

-- Seed 6 tracks (3 existing + 3 new). audience/benefits/syllabus seeded as
-- compact starter JSON; admin can flesh them out via the panel. ON CONFLICT
-- preserves any admin edits across re-runs of this migration.
INSERT INTO course_catalog
    (slug, title, tagline, description, category, difficulty,
     modules_count, labs_count, duration_hours, price_inr, billing_label,
     audience, benefits, syllabus, display_order)
VALUES
    ('linux',
     'Linux Security & Operations Mastery',
     'Forge your Linux blade.',
     'Master the core operating system powering the world''s cybersecurity infrastructure. From bash scripting and file management to advanced system hardening and process control.',
     'System Infrastructure', 'Intermediate', 10, 11, 80, 14999, 'one-time',
     '["Cybersecurity Beginners & Enthusiasts","Aspiring System Administrators","DevOps & Infrastructure Engineers","SOC Analysts & Penetration Testers"]'::jsonb,
     '["Deep understanding of Linux architecture","Advanced Bash automation & scripting","Server security & hardening techniques","Log analysis for threat hunting","Hands-on server troubleshooting","Preparation for industry certifications","Command-line fluency"]'::jsonb,
     '[{"id":1,"title":"Module 1: Linux Fundamentals","lessons":["Intro to Linux","Basic file operations","File searching","Editing files","Redirecting output and pipelines","Wildcards and regular expressions"]},{"id":2,"title":"Module 2: User and Group Management","lessons":["Creating and modifying users","Managing groups","Permission systems"]}]'::jsonb,
     1),
    ('nadpi',
     'Network Analysis & Deep Packet Inspection',
     'See every packet that moves.',
     'Advanced course on packet capture, traffic analysis, encrypted-traffic inspection, and DPI engines (Wireshark, Zeek). Build the muscle to identify malicious traffic in the wild.',
     'Network Analysis', 'Advanced', 5, 3, 60, 14999, 'one-time',
     '["Network Security Engineers","SOC Analysts","Penetration Testers","Threat Hunters"]'::jsonb,
     '["Master Wireshark filters & dissectors","Hands-on Zeek scripting","Encrypted-traffic analysis techniques","DPI engine internals","Real-world capture-the-flag scenarios"]'::jsonb,
     '[{"id":1,"title":"Module 1: Wireshark Fundamentals","lessons":["Capture filters","Display filters","Following streams"]},{"id":2,"title":"Module 2: Zeek (Bro)","lessons":["Zeek scripting","Custom analyzers"]},{"id":3,"title":"Module 3: Deep Packet Inspection","lessons":["Protocol decoding","DPI engines"]},{"id":4,"title":"Module 4: Encrypted Traffic","lessons":["TLS fingerprinting","JA3 hashes"]},{"id":5,"title":"Module 5: Capstone","lessons":["End-to-end traffic analysis project"]}]'::jsonb,
     2),
    ('osint',
     'Open Source Intelligence',
     'Find what others miss.',
     'Open-source intelligence techniques for cybersecurity investigations, corporate due-diligence, and threat-actor profiling. Covers search-engine tradecraft, social media OSINT, and automated collection.',
     'Intelligence', 'Intermediate', 6, 4, 50, 14999, 'one-time',
     '["Investigators & Analysts","Penetration Testers","Threat Intelligence Teams","Corporate Security"]'::jsonb,
     '["Advanced search operators","Social media OSINT tradecraft","Corporate & financial intelligence","Automated collection workflows","Reporting & documentation"]'::jsonb,
     '[{"id":1,"title":"Module 1: OSINT Fundamentals","lessons":["Methodology","Operational security"]},{"id":2,"title":"Module 2: Advanced Search","lessons":["Google dorks","Specialty search engines"]},{"id":3,"title":"Module 3: Corporate & Financial","lessons":["Public records","Filings"]},{"id":4,"title":"Module 4: Automation","lessons":["Maltego transforms","Custom scrapers"]},{"id":5,"title":"Module 5: Reporting","lessons":["Investigative reports","Visual link analysis"]},{"id":6,"title":"Module 6: Capstone","lessons":["Full investigation project"]}]'::jsonb,
     3),
    ('windows',
     'Windows Administration & Hardening',
     'Defend the world''s most-targeted OS.',
     'Hands-on Windows system administration, Active Directory internals, group policy, and host hardening for cybersecurity professionals.',
     'System Infrastructure', 'Intermediate', 8, 9, 70, 14999, 'one-time',
     '["Windows System Administrators","Domain Admins","SOC Analysts","Endpoint Security Engineers"]'::jsonb,
     '["Active Directory fundamentals","Group Policy mastery","PowerShell automation","Host hardening techniques","Incident response on Windows"]'::jsonb,
     '[{"id":1,"title":"Module 1: Windows Fundamentals","lessons":["Architecture","User & group management","File systems"]},{"id":2,"title":"Module 2: Active Directory","lessons":["Domain concepts","Trust relationships"]},{"id":3,"title":"Module 3: Group Policy","lessons":["GPO design","Security baselines"]},{"id":4,"title":"Module 4: PowerShell","lessons":["Scripting","Remoting"]},{"id":5,"title":"Module 5: Hardening","lessons":["CIS benchmarks","Defender configuration"]}]'::jsonb,
     4),
    ('redteam',
     'Red Team Fundamentals',
     'Think like an attacker.',
     'Foundation course for aspiring red team operators. Covers reconnaissance, initial access, privilege escalation, lateral movement, and reporting — all on a controlled lab range.',
     'Red Team', 'Advanced', 7, 8, 90, 14999, 'one-time',
     '["Aspiring Red Team Operators","Penetration Testers","Threat Emulation Engineers","SOC Analysts learning offense"]'::jsonb,
     '["MITRE ATT&CK fluency","Open-source tooling mastery","C2 framework basics","Offensive PowerShell","Engagement reporting"]'::jsonb,
     '[{"id":1,"title":"Module 1: Reconnaissance","lessons":["Passive & active recon","OSINT for red team"]},{"id":2,"title":"Module 2: Initial Access","lessons":["Phishing payloads","Exploit delivery"]},{"id":3,"title":"Module 3: Privilege Escalation","lessons":["Local privesc on Linux & Windows"]},{"id":4,"title":"Module 4: Lateral Movement","lessons":["Pass-the-hash","Kerberoasting"]},{"id":5,"title":"Module 5: Reporting","lessons":["Findings","Remediation guidance"]}]'::jsonb,
     5),
    ('networking',
     'Networking Foundations',
     'Speak the language of the wire.',
     'TCP/IP, routing, switching, and the network protocols every cybersecurity professional needs to understand before they can defend or attack a network.',
     'Networking', 'Beginner', 6, 5, 50, 14999, 'one-time',
     '["Networking Beginners","Cybersecurity Students","Help-Desk Engineers moving into Security","Career Changers"]'::jsonb,
     '["TCP/IP mastery","Routing & switching basics","Common network attacks","Reading packet captures","Network troubleshooting"]'::jsonb,
     '[{"id":1,"title":"Module 1: TCP/IP","lessons":["The four layers","Encapsulation"]},{"id":2,"title":"Module 2: Routing","lessons":["Static & dynamic routing","Common protocols"]},{"id":3,"title":"Module 3: Switching","lessons":["VLANs","Spanning Tree"]},{"id":4,"title":"Module 4: Network Attacks","lessons":["ARP spoofing","DNS poisoning"]},{"id":5,"title":"Module 5: Defensive Networking","lessons":["Firewall rules","Network segmentation"]}]'::jsonb,
     6),
    ('test-course',
     'Test Course',
     'A ₹1 test course for Razorpay integration.',
     'This is a test course priced at ₹1 (plus GST) to verify the Razorpay payment flow end-to-end. Enroll here to confirm your payment setup works.',
     'Testing', 'Beginner', 1, 0, 1, 1, 'one-time',
     '["Anyone testing the platform","Developers verifying payment integration"]'::jsonb,
     '["End-to-end payment flow verification","Razorpay checkout test","GST calculation check"]'::jsonb,
     '[{"id":1,"title":"Module 1: Payment Test","lessons":["Complete purchase","Verify enrollment"]}]'::jsonb,
     7),
    ('the-defender',
     'The Defender',
     'Explore Blue Teaming',
     'An expertly crafted program focusing on essential aspects of cybersecurity defense. This course delves into key topics including Incident Response, Network Defense, & security architecture design. Developed by industry professionals, this course not only imparts crucial knowledge but also equips students with practical skills necessary for effective defense strategies in the ever-changing cybersecurity landscape.',
     'Blue Team', 'Beginner', 1, 0, 1, 1, 'one-time',
     '["Cybersecurity Beginners","Aspiring Blue Team Analysts","SOC Trainees","IT Professionals moving into Security"]'::jsonb,
     '["Incident response fundamentals","Network defense techniques","Security architecture basics","Threat detection skills","Blue team mindset"]'::jsonb,
     '[{"id":1,"title":"Module 1: Blue Team Foundations","lessons":["Introduction to Blue Teaming","Incident Response basics","Network Defense concepts"]}]'::jsonb,
     8),
    ('the-analyst',
     'The Analyst',
     'Explore Purple Teaming',
     'An intensive program tailored to hone skills crucial for cybersecurity analysis. This course covers key topics such as Security Information and Event Management (SIEM), vulnerability patching, and security breach detection. Crafted by Industry experts, the Analyst Course not only imparts vital knowledge but also instills practical proficiency in areas essential for effective cybersecurity analysis in today''s industry.',
     'Purple Team', 'Beginner', 1, 0, 1, 1, 'one-time',
     '["Cybersecurity Students","SOC Analysts","Vulnerability Assessment Engineers","Security Operations Professionals"]'::jsonb,
     '["SIEM fundamentals","Vulnerability patching workflows","Security breach detection","Log analysis skills","Purple team techniques"]'::jsonb,
     '[{"id":1,"title":"Module 1: Analyst Foundations","lessons":["Introduction to SIEM","Vulnerability management","Breach detection basics"]}]'::jsonb,
     9),
    ('the-trailblazer',
     'The Trailblazer',
     'Explore Red Teaming',
     'The Trailblazer Course by Cyber Dojo is an advanced program that covers the latest red teaming concepts in line with cybersecurity industry trends. This comprehensive course explores key topics like ethical hacking, penetration testing, and web application scanning, providing essential knowledge and practical skills for success in the evolving cybersecurity landscape.',
     'Red Team', 'Beginner', 1, 0, 1, 1, 'one-time',
     '["Aspiring Ethical Hackers","Penetration Testers","Red Team Beginners","Security Researchers"]'::jsonb,
     '["Ethical hacking fundamentals","Penetration testing basics","Web application scanning","Red team mindset","Offensive security concepts"]'::jsonb,
     '[{"id":1,"title":"Module 1: Red Team Foundations","lessons":["Introduction to Red Teaming","Ethical hacking overview","Penetration testing basics"]}]'::jsonb,
     10)
ON CONFLICT (slug) DO NOTHING;

-- Auto-update course_catalog.updated_at on row change.
DROP TRIGGER IF EXISTS course_catalog_set_updated_at ON course_catalog;
CREATE TRIGGER course_catalog_set_updated_at
    BEFORE UPDATE ON course_catalog
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();


-- ============================================================
-- COURSE PURCHASES (Part 8b)
-- ============================================================
-- One row per successful Razorpay course purchase. Mirrors credit_transactions
-- but kept separate so course analytics + entitlement queries stay clean.
-- base_price + gst_amount = total_amount (the actual paise charged on the
-- Razorpay order). razorpay_order_id is UNIQUE so a duplicate verify call
-- can't double-record.
CREATE TABLE IF NOT EXISTS course_purchases (
    id                   SERIAL PRIMARY KEY,
    user_id              INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id            INTEGER NOT NULL REFERENCES course_catalog(id),
    course_slug          VARCHAR(50) NOT NULL,
    course_title         VARCHAR(200),
    base_price           NUMERIC(10, 2) NOT NULL,
    gst_amount           NUMERIC(10, 2) NOT NULL,
    total_amount         NUMERIC(10, 2) NOT NULL,
    razorpay_order_id    VARCHAR(64) UNIQUE,
    razorpay_payment_id  VARCHAR(64),
    purchased_at         TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_course_purchases_user ON course_purchases(user_id);
CREATE INDEX IF NOT EXISTS idx_course_purchases_course ON course_purchases(course_id);

-- ============================================================
-- BOOTCAMP CATALOG 
-- ============================================================
-- Mirror of course_catalog for intensive, cohort or specialized bootcamp programs.
CREATE TABLE IF NOT EXISTS bootcamp_catalog (
    id              SERIAL PRIMARY KEY,
    slug            VARCHAR(50) UNIQUE NOT NULL,
    title           VARCHAR(200) NOT NULL,
    tagline         VARCHAR(300),
    description     TEXT,
    category        VARCHAR(50),
    difficulty      VARCHAR(20) CHECK (difficulty IN ('Beginner','Intermediate','Advanced')),
    modules_count   INTEGER,
    labs_count      INTEGER,
    duration_hours  INTEGER,
    price_inr       NUMERIC(10, 2),
    currency        VARCHAR(8)  DEFAULT 'INR',
    billing_label   VARCHAR(50),
    hero_image_url  TEXT,
    accent_color    VARCHAR(20) DEFAULT 'red',
    audience        JSONB NOT NULL DEFAULT '[]'::jsonb,
    benefits        JSONB NOT NULL DEFAULT '[]'::jsonb,
    syllabus        JSONB NOT NULL DEFAULT '[]'::jsonb,
    is_active       BOOLEAN     DEFAULT TRUE,
    display_order   INTEGER     DEFAULT 0,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bootcamp_catalog_active_order ON bootcamp_catalog(is_active, display_order);

-- Auto-update bootcamp_catalog.updated_at on row change.
DROP TRIGGER IF EXISTS bootcamp_catalog_set_updated_at ON bootcamp_catalog;
CREATE TRIGGER bootcamp_catalog_set_updated_at
    BEFORE UPDATE ON bootcamp_catalog
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ============================================================
-- BOOTCAMP PURCHASES
-- ============================================================
CREATE TABLE IF NOT EXISTS bootcamp_purchases (
    id                   SERIAL PRIMARY KEY,
    user_id              INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bootcamp_id          INTEGER NOT NULL REFERENCES bootcamp_catalog(id),
    bootcamp_slug        VARCHAR(50) NOT NULL,
    bootcamp_title       VARCHAR(200),
    base_price           NUMERIC(10, 2) NOT NULL,
    gst_amount           NUMERIC(10, 2) NOT NULL,
    total_amount         NUMERIC(10, 2) NOT NULL,
    razorpay_order_id    VARCHAR(64) UNIQUE,
    razorpay_payment_id  VARCHAR(64),
    purchased_at         TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bootcamp_purchases_user ON bootcamp_purchases(user_id);
CREATE INDEX IF NOT EXISTS idx_bootcamp_purchases_bootcamp ON bootcamp_purchases(bootcamp_id);

-- ============================================================
-- BOOTCAMP PROGRESS 
-- ============================================================
CREATE TABLE IF NOT EXISTS bootcamp_progress (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    bootcamp_name VARCHAR(255) NOT NULL,
    module_name VARCHAR(255) NOT NULL,
    is_completed BOOLEAN DEFAULT TRUE,
    completed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, bootcamp_name, module_name)
);

-- ============================================================
-- UNIVERSITY LMS
-- ============================================================
CREATE TABLE IF NOT EXISTS universities (
    id                   SERIAL PRIMARY KEY,
    name                 VARCHAR(200) NOT NULL,
    slug                 VARCHAR(100) UNIQUE NOT NULL,
    domain               VARCHAR(100),
    enforce_domain       BOOLEAN DEFAULT FALSE,
    logo_url             TEXT,
    description          TEXT,
    credits_per_student  INTEGER DEFAULT 0,
    is_active            BOOLEAN DEFAULT TRUE,
    display_order        INTEGER DEFAULT 0,
    created_at           TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE universities ADD COLUMN IF NOT EXISTS enforce_domain BOOLEAN DEFAULT FALSE;
ALTER TABLE universities ALTER COLUMN domain DROP NOT NULL;
CREATE INDEX IF NOT EXISTS idx_universities_active ON universities(is_active, display_order);

CREATE TABLE IF NOT EXISTS university_programs (
    id                  SERIAL PRIMARY KEY,
    university_id       INTEGER NOT NULL REFERENCES universities(id) ON DELETE CASCADE,
    name                VARCHAR(200) NOT NULL,
    slug                VARCHAR(100) NOT NULL,
    description         TEXT,
    credits_per_student INTEGER DEFAULT 0,
    is_active           BOOLEAN DEFAULT TRUE,
    display_order       INTEGER DEFAULT 0,
    stat_duration       VARCHAR(20),
    stat_labs           VARCHAR(20),
    stat_modules        VARCHAR(20),
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(university_id, slug)
);
CREATE INDEX IF NOT EXISTS idx_uni_programs_univ ON university_programs(university_id);

-- Display-only stats for the LMS "About The Course" row (existing installs).
ALTER TABLE university_programs ADD COLUMN IF NOT EXISTS stat_duration VARCHAR(20);
ALTER TABLE university_programs ADD COLUMN IF NOT EXISTS stat_labs     VARCHAR(20);
ALTER TABLE university_programs ADD COLUMN IF NOT EXISTS stat_modules  VARCHAR(20);


CREATE TABLE IF NOT EXISTS university_semesters (
    id               SERIAL PRIMARY KEY,
    university_id    INTEGER NOT NULL REFERENCES universities(id) ON DELETE CASCADE,
    program_id       INTEGER REFERENCES university_programs(id) ON DELETE CASCADE,
    semester_number  INTEGER NOT NULL,
    name             VARCHAR(200) NOT NULL,
    content          JSONB DEFAULT '[]',
    credits_grant    INTEGER DEFAULT 0,
    links_total      INTEGER,
    links_ok         INTEGER,
    links_warn       INTEGER,
    links_checked_at TIMESTAMPTZ,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_uni_semesters_univ ON university_semesters(university_id);
CREATE INDEX IF NOT EXISTS idx_uni_semesters_prog ON university_semesters(program_id);
ALTER TABLE university_semesters ADD COLUMN IF NOT EXISTS program_id INTEGER REFERENCES university_programs(id) ON DELETE CASCADE;

-- Cached link-reachability summary, so the admin UI can show a status tag
-- without re-fetching every external content URL on page load.
ALTER TABLE university_semesters ADD COLUMN IF NOT EXISTS links_total      INTEGER;
ALTER TABLE university_semesters ADD COLUMN IF NOT EXISTS links_ok         INTEGER;
ALTER TABLE university_semesters ADD COLUMN IF NOT EXISTS links_warn       INTEGER;
ALTER TABLE university_semesters ADD COLUMN IF NOT EXISTS links_checked_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS university_students (
    id                  SERIAL PRIMARY KEY,
    university_id       INTEGER NOT NULL REFERENCES universities(id) ON DELETE CASCADE,
    program_id          INTEGER REFERENCES university_programs(id) ON DELETE SET NULL,
    user_id             INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    current_semester    INTEGER DEFAULT 1,
    status              VARCHAR(20) DEFAULT 'pending',
    lms_paid            BOOLEAN DEFAULT FALSE,
    razorpay_order_id   VARCHAR(64),
    razorpay_payment_id VARCHAR(64),
    enrolled_at         TIMESTAMPTZ DEFAULT NOW(),
    promoted_at         TIMESTAMPTZ,
    UNIQUE(university_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_uni_students_univ ON university_students(university_id);
CREATE INDEX IF NOT EXISTS idx_uni_students_user ON university_students(user_id);
ALTER TABLE university_students ADD COLUMN IF NOT EXISTS program_id INTEGER REFERENCES university_programs(id) ON DELETE SET NULL;

-- These tables are typically created while connected as a superuser, which
-- leaves the app role without access ("permission denied for table ...").
GRANT ALL PRIVILEGES ON TABLE universities         TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE university_programs  TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE university_semesters TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE university_students  TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE universities_id_seq         TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE university_programs_id_seq  TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE university_semesters_id_seq TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE university_students_id_seq  TO dojo_admin;

-- ============================================================
-- BROWSER-DESKTOP (noVNC) LAB
-- ============================================================
-- Backs POST /api/start-lab-gui1. Without this row deduct_credits_or_raise()
-- silently falls back to a cost of 1 credit and the lab never appears in
-- GET /api/labs, so the card is unreachable from the Labs page.
-- Editable afterwards from Admin -> Labs.
INSERT INTO lab_catalog (
    lab_id, slug, name, category, difficulty,
    credits_cost, duration_minutes, os_type, description
) VALUES (
    'gui-lab1',
    'browser-desktop-ubuntu',
    'Browser Desktop (Ubuntu 24.04)',
    'Fundamentals',
    'Easy',
    2,
    120,
    'linux',
    'A full Ubuntu 24.04 desktop that runs in your browser — no RDP or VNC client needed. Opens in a new tab over noVNC.'
) ON CONFLICT (lab_id) DO NOTHING;

-- ============================================================
-- ASSESSMENTS ENGINE
-- ============================================================
CREATE TABLE IF NOT EXISTS assessments (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    slug VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,
    topic VARCHAR(100),
    difficulty VARCHAR(20) DEFAULT 'mixed',
    time_limit_minutes INTEGER DEFAULT 15,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS assessment_questions (
    id SERIAL PRIMARY KEY,
    assessment_id INTEGER NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    question_text TEXT NOT NULL,
    options JSONB NOT NULL,
    correct_answers JSONB NOT NULL,
    multi_select BOOLEAN DEFAULT FALSE,
    order_num INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS assessment_attempts (
    id SERIAL PRIMARY KEY,
    assessment_id INTEGER NOT NULL REFERENCES assessments(id),
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    score INTEGER,
    total_questions INTEGER,
    answers_payload JSONB,
    violations INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'in_progress',
    UNIQUE(assessment_id, user_id)
);

CREATE TABLE IF NOT EXISTS assessment_violations (
    id SERIAL PRIMARY KEY,
    attempt_id INTEGER NOT NULL REFERENCES assessment_attempts(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    violation_type VARCHAR(50) DEFAULT 'tab_switch',
    occurred_at TIMESTAMPTZ DEFAULT NOW()
);

GRANT ALL PRIVILEGES ON TABLE assessments TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE assessment_questions TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE assessment_attempts TO dojo_admin;
GRANT ALL PRIVILEGES ON TABLE assessment_violations TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE assessments_id_seq TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE assessment_questions_id_seq TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE assessment_attempts_id_seq TO dojo_admin;
GRANT USAGE, SELECT ON SEQUENCE assessment_violations_id_seq TO dojo_admin;

INSERT INTO assessments (title, slug, description, topic, difficulty, time_limit_minutes)
VALUES (
    'CSFC Mixed Level Quiz',
    'csfc-mixed',
    'Test your knowledge of Cyber Security Fundamentals. 20 mixed-difficulty questions covering core concepts every security professional must know.',
    'CSFC', 'mixed', 15
) ON CONFLICT (slug) DO NOTHING;

-- Seed CSFC questions (idempotent: only inserts if no questions exist for this assessment)
DO $$
DECLARE aid INTEGER;
BEGIN
    SELECT id INTO aid FROM assessments WHERE slug = 'csfc-mixed';
    IF aid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM assessment_questions WHERE assessment_id = aid) THEN

        INSERT INTO assessment_questions (assessment_id, question_text, options, correct_answers, multi_select, order_num) VALUES
        (aid, 'What does the CIA Triad stand for in information security?',
         '["Confidentiality, Integrity, Availability", "Control, Integrity, Access", "Confidentiality, Intelligence, Assurance", "Cyber, Infrastructure, Authentication"]'::jsonb,
         '[0]'::jsonb, false, 1),

        (aid, 'What is the primary purpose of a firewall?',
         '["Speed up network traffic", "Filter and control network traffic based on rules", "Encrypt all data in transit", "Assign IP addresses to devices"]'::jsonb,
         '[1]'::jsonb, false, 2),

        (aid, 'What type of attack overwhelms a server with traffic to make it unavailable?',
         '["Phishing", "SQL Injection", "Distributed Denial of Service (DDoS)", "Man-in-the-Middle"]'::jsonb,
         '[2]'::jsonb, false, 3),

        (aid, 'What does VPN stand for?',
         '["Virtual Proxy Network", "Virtual Private Network", "Verified Protocol Node", "Variable Public Network"]'::jsonb,
         '[1]'::jsonb, false, 4),

        (aid, 'Which protocol is used to encrypt web traffic in HTTPS?',
         '["TLS (Transport Layer Security)", "FTP (File Transfer Protocol)", "SMTP (Simple Mail Transfer Protocol)", "HTTP/2"]'::jsonb,
         '[0]'::jsonb, false, 5),

        (aid, 'What is phishing?',
         '["A network scanning technique", "A method to crack passwords using brute force", "A deceptive attack tricking users into revealing credentials via fake messages or sites", "A type of malware that encrypts files"]'::jsonb,
         '[2]'::jsonb, false, 6),

        (aid, 'What does MFA stand for?',
         '["Multi-Factor Authentication", "Managed Firewall Access", "Multi-Function Authorization", "Minimal Footprint Architecture"]'::jsonb,
         '[0]'::jsonb, false, 7),

        (aid, 'What is a zero-day vulnerability?',
         '["A flaw discovered and exploited before a patch or fix is available", "A vulnerability rated zero in severity", "A bug introduced on the first day of deployment", "An attack that completes in zero milliseconds"]'::jsonb,
         '[0]'::jsonb, false, 8),

        (aid, 'What is social engineering in cybersecurity?',
         '["Writing malicious code to exploit software bugs", "Using AI to automate network scans", "Building social media platforms for hackers", "Manipulating people psychologically to gain unauthorized access to systems or information"]'::jsonb,
         '[3]'::jsonb, false, 9),

        (aid, 'What does SQL injection exploit?',
         '["Weak encryption algorithms", "Unsanitized database queries that allow attackers to inject malicious SQL code", "Open network ports on a database server", "Outdated SSL certificates"]'::jsonb,
         '[1]'::jsonb, false, 10),

        (aid, 'What is the purpose of a DMZ (Demilitarized Zone) in network security?',
         '["To permanently block all external traffic", "To store encrypted backup data", "A network segment that acts as a buffer zone between the internal network and the internet", "To monitor employee internet usage"]'::jsonb,
         '[2]'::jsonb, false, 11),

        (aid, 'What does HTTPS use to secure communications?',
         '["TLS/SSL certificates to encrypt data between browser and server", "A VPN tunnel for every request", "Two-factor authentication tokens", "IP whitelisting"]'::jsonb,
         '[0]'::jsonb, false, 12),

        (aid, 'What is ransomware?',
         '["Software that monitors user activity for marketing", "Malware that encrypts victim files and demands payment for the decryption key", "A tool used to test network resilience", "Spyware that steals banking credentials"]'::jsonb,
         '[1]'::jsonb, false, 13),

        (aid, 'What is the principle of least privilege?',
         '["Users and systems should be granted only the minimum access rights needed to perform their tasks", "Admins should always have root access to all systems", "Privileges should rotate among all users equally", "Access should default to open and be restricted only when needed"]'::jsonb,
         '[0]'::jsonb, false, 14),

        (aid, 'What is a brute force attack?',
         '["Intercepting encrypted traffic between two parties", "Systematically trying every possible password or key combination until the correct one is found", "Exploiting a known software vulnerability", "Sending malicious email attachments"]'::jsonb,
         '[1]'::jsonb, false, 15),

        (aid, 'What does IDS stand for?',
         '["Internet Defense System", "Intrusion Detection System", "Integrated Data Security", "Internal Diagnostics Suite"]'::jsonb,
         '[1]'::jsonb, false, 16),

        (aid, 'Which of the following is NOT a type of malware?',
         '["Trojan Horse", "Rootkit", "Worm", "VPN (Virtual Private Network)"]'::jsonb,
         '[3]'::jsonb, false, 17),

        (aid, 'What is the purpose of encryption?',
         '["Converting data into an unreadable format that can only be decoded with the correct key", "Compressing data to reduce storage size", "Filtering malicious traffic at the network boundary", "Authenticating users before granting access"]'::jsonb,
         '[0]'::jsonb, false, 18),

        (aid, 'What is a man-in-the-middle (MITM) attack?',
         '["An attack where a hacker plants malware inside a software update", "An attacker secretly intercepts and potentially alters communications between two parties who believe they are communicating directly", "A social engineering technique targeting middle management", "An insider threat from a mid-level employee"]'::jsonb,
         '[1]'::jsonb, false, 19),

        (aid, 'What is a honeypot in cybersecurity?',
         '["A database containing plaintext passwords", "A tool for cracking encrypted hashes", "A trap system designed to lure attackers and study their techniques", "A secure vault for storing cryptographic keys"]'::jsonb,
         '[2]'::jsonb, false, 20);

    END IF;
END $$;

-- ============================================================
-- SEED FIRST SUPERADMIN
-- ============================================================
-- Generate a bcrypt hash on the server:
--     python3 -c "from passlib.context import CryptContext; \
--                 print(CryptContext(schemes=['bcrypt']).hash('YourStrongPassword'))"
-- Then run:
--
-- INSERT INTO admins (email, hashed_password, full_name, role)
-- VALUES ('you@example.com', '<PASTE_BCRYPT_HASH>', 'Your Name', 'superadmin');
