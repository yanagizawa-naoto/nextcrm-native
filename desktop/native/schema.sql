-- Generated from prisma/schema.prisma; decimal values remain exact text.
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS "crm_Accounts" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT NOT NULL,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "annual_revenue" TEXT,
  "assigned_to" TEXT,
  "billing_city" TEXT,
  "billing_country" TEXT,
  "billing_postal_code" TEXT,
  "billing_state" TEXT,
  "billing_street" TEXT,
  "company_id" TEXT,
  "description" TEXT,
  "email" TEXT,
  "employees" TEXT,
  "fax" TEXT,
  "industry" TEXT,
  "member_of" TEXT,
  "name" TEXT NOT NULL,
  "office_phone" TEXT,
  "shipping_city" TEXT,
  "shipping_country" TEXT,
  "shipping_postal_code" TEXT,
  "shipping_state" TEXT,
  "shipping_street" TEXT,
  "status" TEXT,
  "case_study_candidate" INTEGER NOT NULL CHECK ("case_study_candidate" IN (0,1)),
  "case_study_approved" INTEGER NOT NULL CHECK ("case_study_approved" IN (0,1)),
  "type" TEXT,
  "vat" TEXT,
  "website" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "partnerUserId" TEXT,
  "pricelist_id" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("industry") REFERENCES "crm_Industry_Type"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_to") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("partnerUserId") REFERENCES "Users"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("pricelist_id") REFERENCES "crm_PriceLists"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_0" ON "crm_Accounts"("assigned_to");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_1" ON "crm_Accounts"("partnerUserId");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_2" ON "crm_Accounts"("industry");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_3" ON "crm_Accounts"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_4" ON "crm_Accounts"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_5" ON "crm_Accounts"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_6" ON "crm_Accounts"("type");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_7" ON "crm_Accounts"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_8" ON "crm_Accounts"("deletedAt");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_9" ON "crm_Accounts"("pricelist_id");
CREATE TABLE IF NOT EXISTS "crm_Leads" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "firstName" TEXT,
  "lastName" TEXT NOT NULL,
  "company" TEXT,
  "jobTitle" TEXT,
  "email" TEXT,
  "phone" TEXT,
  "description" TEXT,
  "lead_source_id" TEXT,
  "lead_status_id" TEXT,
  "lead_type_id" TEXT,
  "refered_by" TEXT,
  "campaign" TEXT,
  "assigned_to" TEXT,
  "accountsIDs" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("lead_source_id") REFERENCES "crm_Lead_Sources"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("lead_status_id") REFERENCES "crm_Lead_Statuses"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("lead_type_id") REFERENCES "crm_Lead_Types"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_to") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("accountsIDs") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Leads_0" ON "crm_Leads"("assigned_to");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_1" ON "crm_Leads"("accountsIDs");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_2" ON "crm_Leads"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_3" ON "crm_Leads"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_4" ON "crm_Leads"("lead_source_id");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_5" ON "crm_Leads"("lead_status_id");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_6" ON "crm_Leads"("lead_type_id");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_7" ON "crm_Leads"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Leads_8" ON "crm_Leads"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_Contact_Enrichment" (
  "id" TEXT NOT NULL,
  "contactId" TEXT NOT NULL,
  "status" TEXT NOT NULL CHECK ("status" IN ('PENDING','RUNNING','COMPLETED','FAILED','SKIPPED')),
  "fields" TEXT NOT NULL,
  "result" TEXT,
  "error" TEXT,
  "triggeredBy" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("contactId") REFERENCES "crm_Contacts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("triggeredBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Contact_Enrichment_0" ON "crm_Contact_Enrichment"("contactId");
CREATE INDEX IF NOT EXISTS "native_crm_Contact_Enrichment_1" ON "crm_Contact_Enrichment"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Contact_Enrichment_2" ON "crm_Contact_Enrichment"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Contact_Enrichment_3" ON "crm_Contact_Enrichment"("triggeredBy");
CREATE TABLE IF NOT EXISTS "crm_Target_Enrichment" (
  "id" TEXT NOT NULL,
  "targetId" TEXT NOT NULL,
  "status" TEXT NOT NULL CHECK ("status" IN ('PENDING','RUNNING','COMPLETED','FAILED','SKIPPED')),
  "fields" TEXT NOT NULL,
  "result" TEXT,
  "error" TEXT,
  "triggeredBy" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("targetId") REFERENCES "crm_Targets"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("triggeredBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Target_Enrichment_0" ON "crm_Target_Enrichment"("targetId");
CREATE INDEX IF NOT EXISTS "native_crm_Target_Enrichment_1" ON "crm_Target_Enrichment"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Target_Enrichment_2" ON "crm_Target_Enrichment"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Target_Enrichment_3" ON "crm_Target_Enrichment"("triggeredBy");
CREATE TABLE IF NOT EXISTS "crm_Target_Contact" (
  "id" TEXT NOT NULL,
  "targetId" TEXT NOT NULL,
  "contactId" TEXT,
  "name" TEXT,
  "email" TEXT,
  "title" TEXT,
  "phone" TEXT,
  "linkedinUrl" TEXT,
  "source" TEXT NOT NULL,
  "enrichStatus" TEXT NOT NULL CHECK ("enrichStatus" IN ('PENDING','RUNNING','COMPLETED','FAILED','SKIPPED')),
  "enrichedAt" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("targetId") REFERENCES "crm_Targets"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("contactId") REFERENCES "crm_Contacts"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_Target_Contact_0" ON "crm_Target_Contact"("targetId","email");
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_Target_Contact_1" ON "crm_Target_Contact"("targetId","linkedinUrl");
CREATE INDEX IF NOT EXISTS "native_crm_Target_Contact_2" ON "crm_Target_Contact"("targetId");
CREATE INDEX IF NOT EXISTS "native_crm_Target_Contact_3" ON "crm_Target_Contact"("enrichStatus");
CREATE TABLE IF NOT EXISTS "crm_Opportunities" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "account" TEXT,
  "assigned_to" TEXT,
  "budget" TEXT NOT NULL,
  "campaign" TEXT,
  "close_date" TEXT,
  "delivery_deadline" TEXT,
  "stage_entered_at" TEXT,
  "approval_status" TEXT NOT NULL CHECK ("approval_status" IN ('NONE','PENDING','APPROVED','REJECTED')),
  "approval_requested_at" TEXT,
  "approval_note" TEXT,
  "approved_by" TEXT,
  "approved_at" TEXT,
  "contact" TEXT,
  "createdBy" TEXT,
  "created_on" TEXT,
  "createdAt" TEXT NOT NULL,
  "last_activity" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "last_activity_by" TEXT,
  "currency" TEXT,
  "snapshot_rate" TEXT,
  "description" TEXT,
  "expected_revenue" TEXT NOT NULL,
  "name" TEXT,
  "next_step" TEXT,
  "sales_stage" TEXT,
  "type" TEXT,
  "status" TEXT CHECK ("status" IN ('ACTIVE','INACTIVE','PENDING','CLOSED')),
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("type") REFERENCES "crm_Opportunities_Type"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("sales_stage") REFERENCES "crm_Opportunities_Sales_Stages"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_to") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("account") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("campaign") REFERENCES "crm_campaigns"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_0" ON "crm_Opportunities"("account");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_1" ON "crm_Opportunities"("assigned_to");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_2" ON "crm_Opportunities"("campaign");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_3" ON "crm_Opportunities"("contact");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_4" ON "crm_Opportunities"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_5" ON "crm_Opportunities"("sales_stage");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_6" ON "crm_Opportunities"("type");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_7" ON "crm_Opportunities"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_8" ON "crm_Opportunities"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_9" ON "crm_Opportunities"("close_date");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_10" ON "crm_Opportunities"("status","sales_stage");
CREATE INDEX IF NOT EXISTS "native_crm_Opportunities_11" ON "crm_Opportunities"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_campaigns" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "status" TEXT,
  "template_id" TEXT,
  "from_name" TEXT,
  "reply_to" TEXT,
  "scheduled_at" TEXT,
  "sent_at" TEXT,
  "created_by" TEXT,
  "created_on" TEXT,
  "updatedAt" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("template_id") REFERENCES "crm_campaign_templates"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("created_by") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_campaigns_0" ON "crm_campaigns"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_campaign_templates" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "subject_default" TEXT,
  "content_html" TEXT NOT NULL,
  "content_json" TEXT NOT NULL,
  "created_by" TEXT,
  "created_on" TEXT,
  "updatedAt" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("created_by") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_campaign_templates_0" ON "crm_campaign_templates"("created_by");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_templates_1" ON "crm_campaign_templates"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_campaign_steps" (
  "id" TEXT NOT NULL,
  "campaign_id" TEXT NOT NULL,
  "order" INTEGER NOT NULL,
  "template_id" TEXT NOT NULL,
  "subject" TEXT NOT NULL,
  "delay_days" INTEGER NOT NULL,
  "send_to" TEXT NOT NULL,
  "scheduled_at" TEXT,
  "sent_at" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("campaign_id") REFERENCES "crm_campaigns"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("template_id") REFERENCES "crm_campaign_templates"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_campaign_steps_0" ON "crm_campaign_steps"("campaign_id","order");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_steps_1" ON "crm_campaign_steps"("campaign_id");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_steps_2" ON "crm_campaign_steps"("scheduled_at");
CREATE TABLE IF NOT EXISTS "CampaignToTargetLists" (
  "campaign_id" TEXT NOT NULL,
  "target_list_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("campaign_id","target_list_id"),
  FOREIGN KEY ("campaign_id") REFERENCES "crm_campaigns"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("target_list_id") REFERENCES "crm_TargetLists"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_campaign_sends" (
  "id" TEXT NOT NULL,
  "campaign_id" TEXT NOT NULL,
  "step_id" TEXT NOT NULL,
  "target_id" TEXT NOT NULL,
  "email" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "resend_message_id" TEXT,
  "unsubscribe_token" TEXT NOT NULL UNIQUE,
  "opened_at" TEXT,
  "clicked_at" TEXT,
  "unsubscribed_at" TEXT,
  "error_message" TEXT,
  "sent_at" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("campaign_id") REFERENCES "crm_campaigns"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("step_id") REFERENCES "crm_campaign_steps"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("target_id") REFERENCES "crm_Targets"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_campaign_sends_0" ON "crm_campaign_sends"("step_id","target_id");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_sends_1" ON "crm_campaign_sends"("campaign_id");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_sends_2" ON "crm_campaign_sends"("step_id","target_id");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_sends_3" ON "crm_campaign_sends"("resend_message_id");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_sends_4" ON "crm_campaign_sends"("status");
CREATE INDEX IF NOT EXISTS "native_crm_campaign_sends_5" ON "crm_campaign_sends"("unsubscribe_token");
CREATE TABLE IF NOT EXISTS "crm_Opportunities_Sales_Stages" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "probability" INTEGER,
  "order" INTEGER,
  "stage_kind" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "crm_FunnelSettings" (
  "id" TEXT NOT NULL,
  "kill_after_days" INTEGER NOT NULL,
  "recycle_after_days" INTEGER NOT NULL,
  "cadence_touch1_business_days" INTEGER NOT NULL,
  "cadence_touch2_offset_days" INTEGER NOT NULL,
  "cadence_touch3_offset_days" INTEGER NOT NULL,
  "cadence_touch4_offset_days" INTEGER NOT NULL,
  "cadence_touch5_offset_days" INTEGER NOT NULL,
  "care_checkin_days" INTEGER NOT NULL,
  "care_referral_days" INTEGER NOT NULL,
  "care_quarter_interval_days" INTEGER NOT NULL,
  "care_quarter_count" INTEGER NOT NULL,
  "renewal_window_days" INTEGER NOT NULL,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "crm_Opportunities_Type" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "order" INTEGER,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "crm_Contact_Types" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL UNIQUE,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_crm_Contact_Types_0" ON "crm_Contact_Types"("name");
CREATE TABLE IF NOT EXISTS "crm_Lead_Sources" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL UNIQUE,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_crm_Lead_Sources_0" ON "crm_Lead_Sources"("name");
CREATE TABLE IF NOT EXISTS "crm_Lead_Statuses" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL UNIQUE,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_crm_Lead_Statuses_0" ON "crm_Lead_Statuses"("name");
CREATE TABLE IF NOT EXISTS "crm_Lead_Types" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL UNIQUE,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_crm_Lead_Types_0" ON "crm_Lead_Types"("name");
CREATE TABLE IF NOT EXISTS "crm_Contacts" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "account" TEXT,
  "assigned_to" TEXT,
  "birthday" TEXT,
  "createdBy" TEXT,
  "created_on" TEXT,
  "cratedAt" TEXT,
  "last_activity" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "last_activity_by" TEXT,
  "description" TEXT,
  "email" TEXT,
  "personal_email" TEXT,
  "first_name" TEXT,
  "last_name" TEXT NOT NULL,
  "office_phone" TEXT,
  "mobile_phone" TEXT,
  "website" TEXT,
  "position" TEXT,
  "status" INTEGER NOT NULL CHECK ("status" IN (0,1)),
  "social_twitter" TEXT,
  "social_facebook" TEXT,
  "social_linkedin" TEXT,
  "social_skype" TEXT,
  "social_instagram" TEXT,
  "social_youtube" TEXT,
  "social_tiktok" TEXT,
  "contact_type_id" TEXT,
  "tags" TEXT NOT NULL,
  "notes" TEXT NOT NULL,
  "accountsIDs" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("contact_type_id") REFERENCES "crm_Contact_Types"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_to") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("accountsIDs") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_0" ON "crm_Contacts"("assigned_to");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_1" ON "crm_Contacts"("accountsIDs");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_2" ON "crm_Contacts"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_3" ON "crm_Contacts"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_4" ON "crm_Contacts"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_5" ON "crm_Contacts"("contact_type_id");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_6" ON "crm_Contacts"("cratedAt");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_7" ON "crm_Contacts"("last_activity");
CREATE INDEX IF NOT EXISTS "native_crm_Contacts_8" ON "crm_Contacts"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_Contracts" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "title" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  "startDate" TEXT,
  "endDate" TEXT,
  "renewalReminderDate" TEXT,
  "customerSignedDate" TEXT,
  "companySignedDate" TEXT,
  "description" TEXT,
  "account" TEXT,
  "assigned_to" TEXT,
  "createdAt" TEXT,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "status" TEXT NOT NULL CHECK ("status" IN ('NOTSTARTED','INPROGRESS','SIGNED')),
  "type" TEXT,
  "currency" TEXT,
  "snapshot_rate" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_to") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_0" ON "crm_Contracts"("account");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_1" ON "crm_Contracts"("assigned_to");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_2" ON "crm_Contracts"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_3" ON "crm_Contracts"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_4" ON "crm_Contracts"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_5" ON "crm_Contracts"("startDate");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_6" ON "crm_Contracts"("endDate");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_7" ON "crm_Contracts"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_8" ON "crm_Contracts"("startDate","endDate");
CREATE INDEX IF NOT EXISTS "native_crm_Contracts_9" ON "crm_Contracts"("deletedAt");
CREATE TABLE IF NOT EXISTS "Currency" (
  "code" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "symbol" TEXT NOT NULL,
  "isEnabled" INTEGER NOT NULL CHECK ("isEnabled" IN (0,1)),
  "isDefault" INTEGER NOT NULL CHECK ("isDefault" IN (0,1)),
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("code")
);
CREATE TABLE IF NOT EXISTS "ExchangeRate" (
  "id" TEXT NOT NULL,
  "fromCurrency" TEXT NOT NULL,
  "toCurrency" TEXT NOT NULL,
  "rate" TEXT NOT NULL,
  "source" TEXT NOT NULL CHECK ("source" IN ('MANUAL','ECB')),
  "effectiveDate" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("fromCurrency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("toCurrency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_ExchangeRate_0" ON "ExchangeRate"("fromCurrency","toCurrency");
CREATE INDEX IF NOT EXISTS "native_ExchangeRate_1" ON "ExchangeRate"("fromCurrency");
CREATE INDEX IF NOT EXISTS "native_ExchangeRate_2" ON "ExchangeRate"("toCurrency");
CREATE TABLE IF NOT EXISTS "crm_SystemSettings" (
  "key" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("key")
);
CREATE TABLE IF NOT EXISTS "crm_Activities" (
  "id" TEXT NOT NULL,
  "type" TEXT NOT NULL CHECK ("type" IN ('call','meeting','note','email','visit')),
  "title" TEXT NOT NULL,
  "description" TEXT,
  "date" TEXT NOT NULL,
  "duration" INTEGER,
  "outcome" TEXT,
  "status" TEXT NOT NULL CHECK ("status" IN ('scheduled','completed','cancelled')),
  "metadata" TEXT,
  "createdBy" TEXT,
  "updatedBy" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("updatedBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Activities_0" ON "crm_Activities"("date");
CREATE INDEX IF NOT EXISTS "native_crm_Activities_1" ON "crm_Activities"("type");
CREATE INDEX IF NOT EXISTS "native_crm_Activities_2" ON "crm_Activities"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Activities_3" ON "crm_Activities"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Activities_4" ON "crm_Activities"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Activities_5" ON "crm_Activities"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_ActivityLinks" (
  "id" TEXT NOT NULL,
  "activityId" TEXT NOT NULL,
  "entityType" TEXT NOT NULL,
  "entityId" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("activityId") REFERENCES "crm_Activities"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_ActivityLinks_0" ON "crm_ActivityLinks"("activityId");
CREATE INDEX IF NOT EXISTS "native_crm_ActivityLinks_1" ON "crm_ActivityLinks"("entityType","entityId","activityId");
CREATE TABLE IF NOT EXISTS "Boards" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "description" TEXT NOT NULL,
  "favourite" INTEGER CHECK ("favourite" IN (0,1)),
  "favouritePosition" INTEGER,
  "icon" TEXT,
  "position" INTEGER,
  "title" TEXT NOT NULL,
  "user" TEXT NOT NULL,
  "visibility" TEXT,
  "sharedWith" TEXT NOT NULL,
  "createdAt" TEXT,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Boards_0" ON "Boards"("user");
CREATE INDEX IF NOT EXISTS "native_Boards_1" ON "Boards"("createdBy");
CREATE INDEX IF NOT EXISTS "native_Boards_2" ON "Boards"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_Boards_3" ON "Boards"("favourite");
CREATE INDEX IF NOT EXISTS "native_Boards_4" ON "Boards"("visibility");
CREATE INDEX IF NOT EXISTS "native_Boards_5" ON "Boards"("createdAt");
CREATE INDEX IF NOT EXISTS "native_Boards_6" ON "Boards"("user","favourite");
CREATE INDEX IF NOT EXISTS "native_Boards_7" ON "Boards"("deletedAt");
CREATE TABLE IF NOT EXISTS "Employees" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "avatar" TEXT NOT NULL,
  "email" TEXT,
  "name" TEXT NOT NULL,
  "salary" INTEGER NOT NULL,
  "status" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "ImageUpload" (
  "id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Documents" (
  "id" TEXT NOT NULL,
  "__v" INTEGER,
  "date_created" TEXT,
  "createdAt" TEXT,
  "last_updated" TEXT,
  "updatedAt" TEXT,
  "document_name" TEXT NOT NULL,
  "created_by_user" TEXT,
  "createdBy" TEXT,
  "description" TEXT,
  "document_type" TEXT,
  "favourite" INTEGER CHECK ("favourite" IN (0,1)),
  "document_file_mimeType" TEXT NOT NULL,
  "document_file_url" TEXT NOT NULL,
  "status" TEXT,
  "visibility" TEXT,
  "tags" TEXT,
  "key" TEXT,
  "size" INTEGER,
  "assigned_user" TEXT,
  "connected_documents" TEXT NOT NULL,
  "content_text" TEXT,
  "summary" TEXT,
  "content_hash" TEXT,
  "thumbnail_url" TEXT,
  "processing_status" TEXT NOT NULL CHECK ("processing_status" IN ('PENDING','PROCESSING','READY','FAILED')),
  "processing_error" TEXT,
  "version" INTEGER NOT NULL,
  "parent_document_id" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "document_system_type" TEXT CHECK ("document_system_type" IN ('RECEIPT','CONTRACT','OFFER','OTHER')),
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("created_by_user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("assigned_user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("document_type") REFERENCES "Documents_Types"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("parent_document_id") REFERENCES "Documents"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Documents_0" ON "Documents"("created_by_user");
CREATE INDEX IF NOT EXISTS "native_Documents_1" ON "Documents"("assigned_user");
CREATE INDEX IF NOT EXISTS "native_Documents_2" ON "Documents"("document_type");
CREATE INDEX IF NOT EXISTS "native_Documents_3" ON "Documents"("createdBy");
CREATE INDEX IF NOT EXISTS "native_Documents_4" ON "Documents"("status");
CREATE INDEX IF NOT EXISTS "native_Documents_5" ON "Documents"("visibility");
CREATE INDEX IF NOT EXISTS "native_Documents_6" ON "Documents"("favourite");
CREATE INDEX IF NOT EXISTS "native_Documents_7" ON "Documents"("createdAt");
CREATE INDEX IF NOT EXISTS "native_Documents_8" ON "Documents"("document_system_type");
CREATE INDEX IF NOT EXISTS "native_Documents_9" ON "Documents"("content_hash");
CREATE INDEX IF NOT EXISTS "native_Documents_10" ON "Documents"("parent_document_id");
CREATE INDEX IF NOT EXISTS "native_Documents_11" ON "Documents"("processing_status");
CREATE INDEX IF NOT EXISTS "native_Documents_12" ON "Documents"("deletedAt");
CREATE TABLE IF NOT EXISTS "Documents_Types" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Sections" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "board" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "position" INTEGER,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("board") REFERENCES "Boards"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Sections_0" ON "Sections"("board");
CREATE TABLE IF NOT EXISTS "crm_Industry_Type" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Tasks" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "content" TEXT,
  "createdAt" TEXT,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "dueDateAt" TEXT,
  "lastEditedAt" TEXT,
  "position" INTEGER NOT NULL,
  "priority" TEXT NOT NULL,
  "section" TEXT,
  "tags" TEXT,
  "title" TEXT NOT NULL,
  "likes" INTEGER,
  "user" TEXT,
  "taskStatus" TEXT CHECK ("taskStatus" IN ('ACTIVE','PENDING','COMPLETE')),
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("section") REFERENCES "Sections"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Tasks_0" ON "Tasks"("user");
CREATE INDEX IF NOT EXISTS "native_Tasks_1" ON "Tasks"("section");
CREATE INDEX IF NOT EXISTS "native_Tasks_2" ON "Tasks"("createdBy");
CREATE INDEX IF NOT EXISTS "native_Tasks_3" ON "Tasks"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_Tasks_4" ON "Tasks"("priority");
CREATE INDEX IF NOT EXISTS "native_Tasks_5" ON "Tasks"("taskStatus");
CREATE INDEX IF NOT EXISTS "native_Tasks_6" ON "Tasks"("dueDateAt");
CREATE INDEX IF NOT EXISTS "native_Tasks_7" ON "Tasks"("createdAt");
CREATE INDEX IF NOT EXISTS "native_Tasks_8" ON "Tasks"("user","taskStatus");
CREATE TABLE IF NOT EXISTS "crm_Accounts_Tasks" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "content" TEXT,
  "createdAt" TEXT,
  "createdBy" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "dueDateAt" TEXT,
  "priority" TEXT NOT NULL,
  "tags" TEXT,
  "title" TEXT NOT NULL,
  "likes" INTEGER,
  "user" TEXT,
  "taskStatus" TEXT CHECK ("taskStatus" IN ('ACTIVE','PENDING','COMPLETE')),
  "account" TEXT,
  "opportunity_id" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("account") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("opportunity_id") REFERENCES "crm_Opportunities"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_0" ON "crm_Accounts_Tasks"("user");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_1" ON "crm_Accounts_Tasks"("account");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_2" ON "crm_Accounts_Tasks"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_3" ON "crm_Accounts_Tasks"("updatedBy");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_4" ON "crm_Accounts_Tasks"("priority");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_5" ON "crm_Accounts_Tasks"("taskStatus");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_6" ON "crm_Accounts_Tasks"("dueDateAt");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_7" ON "crm_Accounts_Tasks"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_8" ON "crm_Accounts_Tasks"("account","taskStatus");
CREATE INDEX IF NOT EXISTS "native_crm_Accounts_Tasks_9" ON "crm_Accounts_Tasks"("opportunity_id");
CREATE TABLE IF NOT EXISTS "tasksComments" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "comment" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "task" TEXT,
  "user" TEXT NOT NULL,
  "assigned_crm_account_task" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("assigned_crm_account_task") REFERENCES "crm_Accounts_Tasks"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("task") REFERENCES "Tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("user") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_tasksComments_0" ON "tasksComments"("task");
CREATE INDEX IF NOT EXISTS "native_tasksComments_1" ON "tasksComments"("user");
CREATE INDEX IF NOT EXISTS "native_tasksComments_2" ON "tasksComments"("assigned_crm_account_task");
CREATE TABLE IF NOT EXISTS "TodoList" (
  "id" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "description" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "url" TEXT NOT NULL,
  "user" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Users" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "account_name" TEXT,
  "avatar" TEXT,
  "email" TEXT NOT NULL UNIQUE,
  "emailVerified" INTEGER NOT NULL CHECK ("emailVerified" IN (0,1)),
  "image" TEXT,
  "role" TEXT NOT NULL CHECK ("role" IN ('user','manager','admin','partner')),
  "created_on" TEXT NOT NULL,
  "updated_at" TEXT,
  "lastLoginAt" TEXT,
  "name" TEXT,
  "password" TEXT,
  "username" TEXT,
  "userStatus" TEXT NOT NULL CHECK ("userStatus" IN ('ACTIVE','INACTIVE','PENDING')),
  "userLanguage" TEXT NOT NULL CHECK ("userLanguage" IN ('ja','cz','en','de','uk')),
  "banned" INTEGER NOT NULL CHECK ("banned" IN (0,1)),
  "banReason" TEXT,
  "banExpires" TEXT,
  "partnerAccountId" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("partnerAccountId") REFERENCES "crm_Accounts"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Users_0" ON "Users"("email");
CREATE INDEX IF NOT EXISTS "native_Users_1" ON "Users"("userStatus");
CREATE INDEX IF NOT EXISTS "native_Users_2" ON "Users"("userLanguage");
CREATE INDEX IF NOT EXISTS "native_Users_3" ON "Users"("role");
CREATE INDEX IF NOT EXISTS "native_Users_4" ON "Users"("partnerAccountId");
CREATE INDEX IF NOT EXISTS "native_Users_5" ON "Users"("created_on");
CREATE INDEX IF NOT EXISTS "native_Users_6" ON "Users"("lastLoginAt");
CREATE TABLE IF NOT EXISTS "crm_AuditLog" (
  "id" TEXT NOT NULL,
  "entityType" TEXT NOT NULL,
  "entityId" TEXT NOT NULL,
  "action" TEXT NOT NULL CHECK ("action" IN ('created','updated','deleted','restored','relation_added','relation_removed','installed','uninstalled','enabled','disabled','settings_changed','upgraded','imported','cancelled')),
  "changes" TEXT,
  "userId" TEXT,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_AuditLog_0" ON "crm_AuditLog"("entityType","entityId","createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_AuditLog_1" ON "crm_AuditLog"("userId");
CREATE INDEX IF NOT EXISTS "native_crm_AuditLog_2" ON "crm_AuditLog"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_AuditLog_3" ON "crm_AuditLog"("entityType","createdAt");
CREATE TABLE IF NOT EXISTS "crm_Report_Config" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "category" TEXT NOT NULL,
  "filters" TEXT NOT NULL,
  "isShared" INTEGER NOT NULL CHECK ("isShared" IN (0,1)),
  "createdBy" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Report_Config_0" ON "crm_Report_Config"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Report_Config_1" ON "crm_Report_Config"("category");
CREATE INDEX IF NOT EXISTS "native_crm_Report_Config_2" ON "crm_Report_Config"("isShared");
CREATE TABLE IF NOT EXISTS "crm_Report_Schedule" (
  "id" TEXT NOT NULL,
  "reportConfigId" TEXT NOT NULL,
  "cronExpression" TEXT NOT NULL,
  "recipients" TEXT NOT NULL,
  "format" TEXT NOT NULL,
  "isActive" INTEGER NOT NULL CHECK ("isActive" IN (0,1)),
  "lastSentAt" TEXT,
  "createdBy" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("reportConfigId") REFERENCES "crm_Report_Config"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Report_Schedule_0" ON "crm_Report_Schedule"("reportConfigId");
CREATE INDEX IF NOT EXISTS "native_crm_Report_Schedule_1" ON "crm_Report_Schedule"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Report_Schedule_2" ON "crm_Report_Schedule"("isActive");
CREATE INDEX IF NOT EXISTS "native_crm_Report_Schedule_3" ON "crm_Report_Schedule"("lastSentAt");
CREATE TABLE IF NOT EXISTS "ApiKeys" (
  "id" TEXT NOT NULL,
  "scope" TEXT NOT NULL CHECK ("scope" IN ('SYSTEM','USER')),
  "userId" TEXT,
  "provider" TEXT NOT NULL CHECK ("provider" IN ('OPENAI','FIRECRAWL','ANTHROPIC','GROQ')),
  "encryptedKey" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_ApiKeys_0" ON "ApiKeys"("scope","provider");
CREATE INDEX IF NOT EXISTS "native_ApiKeys_1" ON "ApiKeys"("userId","provider");
CREATE TABLE IF NOT EXISTS "systemServices" (
  "id" TEXT NOT NULL,
  "__v" INTEGER NOT NULL,
  "name" TEXT NOT NULL,
  "serviceUrl" TEXT,
  "serviceId" TEXT,
  "serviceKey" TEXT,
  "servicePassword" TEXT,
  "servicePort" TEXT,
  "description" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "DocumentsToOpportunities" (
  "document_id" TEXT NOT NULL,
  "opportunity_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","opportunity_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("opportunity_id") REFERENCES "crm_Opportunities"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToOpportunities_1" ON "DocumentsToOpportunities"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToOpportunities_2" ON "DocumentsToOpportunities"("opportunity_id");
CREATE TABLE IF NOT EXISTS "DocumentsToContacts" (
  "document_id" TEXT NOT NULL,
  "contact_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","contact_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("contact_id") REFERENCES "crm_Contacts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToContacts_1" ON "DocumentsToContacts"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToContacts_2" ON "DocumentsToContacts"("contact_id");
CREATE TABLE IF NOT EXISTS "DocumentsToTasks" (
  "document_id" TEXT NOT NULL,
  "task_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","task_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("task_id") REFERENCES "Tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToTasks_1" ON "DocumentsToTasks"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToTasks_2" ON "DocumentsToTasks"("task_id");
CREATE TABLE IF NOT EXISTS "DocumentsToCrmAccountsTasks" (
  "document_id" TEXT NOT NULL,
  "crm_accounts_task_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","crm_accounts_task_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("crm_accounts_task_id") REFERENCES "crm_Accounts_Tasks"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToCrmAccountsTasks_1" ON "DocumentsToCrmAccountsTasks"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToCrmAccountsTasks_2" ON "DocumentsToCrmAccountsTasks"("crm_accounts_task_id");
CREATE TABLE IF NOT EXISTS "DocumentsToLeads" (
  "document_id" TEXT NOT NULL,
  "lead_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","lead_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("lead_id") REFERENCES "crm_Leads"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToLeads_1" ON "DocumentsToLeads"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToLeads_2" ON "DocumentsToLeads"("lead_id");
CREATE TABLE IF NOT EXISTS "DocumentsToAccounts" (
  "document_id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("document_id","account_id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("account_id") REFERENCES "crm_Accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_DocumentsToAccounts_1" ON "DocumentsToAccounts"("document_id");
CREATE INDEX IF NOT EXISTS "native_DocumentsToAccounts_2" ON "DocumentsToAccounts"("account_id");
CREATE TABLE IF NOT EXISTS "AccountWatchers" (
  "account_id" TEXT NOT NULL,
  "user_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("account_id","user_id"),
  FOREIGN KEY ("account_id") REFERENCES "crm_Accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("user_id") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_AccountWatchers_1" ON "AccountWatchers"("account_id");
CREATE INDEX IF NOT EXISTS "native_AccountWatchers_2" ON "AccountWatchers"("user_id");
CREATE TABLE IF NOT EXISTS "BoardWatchers" (
  "board_id" TEXT NOT NULL,
  "user_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("board_id","user_id"),
  FOREIGN KEY ("board_id") REFERENCES "Boards"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("user_id") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_BoardWatchers_1" ON "BoardWatchers"("board_id");
CREATE INDEX IF NOT EXISTS "native_BoardWatchers_2" ON "BoardWatchers"("user_id");
CREATE TABLE IF NOT EXISTS "ContactsToOpportunities" (
  "contact_id" TEXT NOT NULL,
  "opportunity_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("contact_id","opportunity_id"),
  FOREIGN KEY ("contact_id") REFERENCES "crm_Contacts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("opportunity_id") REFERENCES "crm_Opportunities"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_ContactsToOpportunities_1" ON "ContactsToOpportunities"("contact_id");
CREATE INDEX IF NOT EXISTS "native_ContactsToOpportunities_2" ON "ContactsToOpportunities"("opportunity_id");
CREATE TABLE IF NOT EXISTS "crm_Targets" (
  "id" TEXT NOT NULL,
  "first_name" TEXT,
  "last_name" TEXT NOT NULL,
  "email" TEXT,
  "mobile_phone" TEXT,
  "office_phone" TEXT,
  "company" TEXT,
  "company_website" TEXT,
  "personal_website" TEXT,
  "position" TEXT,
  "social_x" TEXT,
  "social_linkedin" TEXT,
  "social_instagram" TEXT,
  "social_facebook" TEXT,
  "status" INTEGER NOT NULL CHECK ("status" IN (0,1)),
  "do_not_email" INTEGER NOT NULL CHECK ("do_not_email" IN (0,1)),
  "do_not_email_at" TEXT,
  "tags" TEXT NOT NULL,
  "notes" TEXT NOT NULL,
  "created_by" TEXT,
  "created_on" TEXT,
  "updatedAt" TEXT,
  "updatedBy" TEXT,
  "personal_email" TEXT,
  "company_email" TEXT,
  "company_phone" TEXT,
  "city" TEXT,
  "country" TEXT,
  "industry" TEXT,
  "employees" TEXT,
  "description" TEXT,
  "converted_at" TEXT,
  "converted_account_id" TEXT,
  "converted_contact_id" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("created_by") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("converted_account_id") REFERENCES "crm_Accounts"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("converted_contact_id") REFERENCES "crm_Contacts"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Targets_0" ON "crm_Targets"("created_by");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_1" ON "crm_Targets"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_2" ON "crm_Targets"("created_on");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_3" ON "crm_Targets"("converted_account_id");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_4" ON "crm_Targets"("do_not_email");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_5" ON "crm_Targets"("converted_contact_id");
CREATE INDEX IF NOT EXISTS "native_crm_Targets_6" ON "crm_Targets"("deletedAt");
CREATE TABLE IF NOT EXISTS "crm_TargetLists" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "status" INTEGER NOT NULL CHECK ("status" IN (0,1)),
  "created_by" TEXT,
  "created_on" TEXT,
  "updatedAt" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("created_by") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_TargetLists_0" ON "crm_TargetLists"("created_by");
CREATE INDEX IF NOT EXISTS "native_crm_TargetLists_1" ON "crm_TargetLists"("status");
CREATE INDEX IF NOT EXISTS "native_crm_TargetLists_2" ON "crm_TargetLists"("deletedAt");
CREATE TABLE IF NOT EXISTS "TargetsToTargetLists" (
  "target_id" TEXT NOT NULL,
  "target_list_id" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("target_id","target_list_id"),
  FOREIGN KEY ("target_id") REFERENCES "crm_Targets"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("target_list_id") REFERENCES "crm_TargetLists"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_TargetsToTargetLists_1" ON "TargetsToTargetLists"("target_id");
CREATE INDEX IF NOT EXISTS "native_TargetsToTargetLists_2" ON "TargetsToTargetLists"("target_list_id");
CREATE TABLE IF NOT EXISTS "crm_Embeddings_Accounts" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "content_hash" TEXT NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "crm_Accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_Embeddings_Contacts" (
  "id" TEXT NOT NULL,
  "contact_id" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "content_hash" TEXT NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("contact_id") REFERENCES "crm_Contacts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_Embeddings_Leads" (
  "id" TEXT NOT NULL,
  "lead_id" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "content_hash" TEXT NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("lead_id") REFERENCES "crm_Leads"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_Embeddings_Opportunities" (
  "id" TEXT NOT NULL,
  "opportunity_id" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "content_hash" TEXT NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("opportunity_id") REFERENCES "crm_Opportunities"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_Embeddings_Documents" (
  "id" TEXT NOT NULL,
  "document_id" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "content_hash" TEXT NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "crm_Document_Chunks" (
  "id" TEXT NOT NULL,
  "document_id" TEXT NOT NULL,
  "chunk_index" INTEGER NOT NULL,
  "chunk_text" TEXT NOT NULL,
  "embedding" BLOB NOT NULL,
  "embedded_at" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("document_id") REFERENCES "Documents"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Document_Chunks_0" ON "crm_Document_Chunks"("document_id");
CREATE TABLE IF NOT EXISTS "ApiToken" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "tokenHash" TEXT NOT NULL UNIQUE,
  "tokenPrefix" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "expiresAt" TEXT,
  "revokedAt" TEXT,
  "lastUsedAt" TEXT,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_ApiToken_0" ON "ApiToken"("userId");
CREATE TABLE IF NOT EXISTS "EmailAccount" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "label" TEXT NOT NULL,
  "imapHost" TEXT NOT NULL,
  "imapPort" INTEGER NOT NULL,
  "imapSsl" INTEGER NOT NULL CHECK ("imapSsl" IN (0,1)),
  "smtpHost" TEXT NOT NULL,
  "smtpPort" INTEGER NOT NULL,
  "smtpSsl" INTEGER NOT NULL CHECK ("smtpSsl" IN (0,1)),
  "allowSelfSignedTls" INTEGER NOT NULL CHECK ("allowSelfSignedTls" IN (0,1)),
  "username" TEXT NOT NULL,
  "passwordEncrypted" TEXT NOT NULL,
  "isActive" INTEGER NOT NULL CHECK ("isActive" IN (0,1)),
  "sentFolderName" TEXT NOT NULL,
  "lastSyncedAt" TEXT,
  "inboxLastUid" INTEGER,
  "sentLastUid" INTEGER,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_EmailAccount_0" ON "EmailAccount"("userId");
CREATE INDEX IF NOT EXISTS "native_EmailAccount_1" ON "EmailAccount"("isActive");
CREATE TABLE IF NOT EXISTS "Email" (
  "id" TEXT NOT NULL,
  "emailAccountId" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "rfcMessageId" TEXT NOT NULL,
  "imapUid" INTEGER,
  "folder" TEXT NOT NULL CHECK ("folder" IN ('INBOX','SENT')),
  "subject" TEXT,
  "fromName" TEXT,
  "fromEmail" TEXT,
  "toRecipients" TEXT NOT NULL,
  "ccRecipients" TEXT NOT NULL,
  "bccRecipients" TEXT NOT NULL,
  "bodyText" TEXT,
  "bodyHtml" TEXT,
  "sentAt" TEXT,
  "isRead" INTEGER NOT NULL CHECK ("isRead" IN (0,1)),
  "isDeleted" INTEGER NOT NULL CHECK ("isDeleted" IN (0,1)),
  "updatedAt" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("emailAccountId") REFERENCES "EmailAccount"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_Email_0" ON "Email"("emailAccountId","rfcMessageId");
CREATE INDEX IF NOT EXISTS "native_Email_1" ON "Email"("userId");
CREATE INDEX IF NOT EXISTS "native_Email_2" ON "Email"("emailAccountId");
CREATE INDEX IF NOT EXISTS "native_Email_3" ON "Email"("folder");
CREATE INDEX IF NOT EXISTS "native_Email_4" ON "Email"("isDeleted");
CREATE INDEX IF NOT EXISTS "native_Email_5" ON "Email"("sentAt");
CREATE INDEX IF NOT EXISTS "native_Email_6" ON "Email"("userId","folder","isDeleted","isRead");
CREATE TABLE IF NOT EXISTS "EmailEmbedding" (
  "id" TEXT NOT NULL,
  "emailId" TEXT NOT NULL UNIQUE,
  "embedding" BLOB NOT NULL,
  "contentHash" TEXT NOT NULL,
  "embeddedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("emailId") REFERENCES "Email"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "CalendarConnection" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "provider" TEXT NOT NULL CHECK ("provider" IN ('google')),
  "accountEmail" TEXT NOT NULL,
  "accessTokenEncrypted" TEXT,
  "refreshTokenEncrypted" TEXT NOT NULL,
  "tokenExpiresAt" TEXT,
  "syncToken" TEXT,
  "scopeLevel" TEXT NOT NULL,
  "isActive" INTEGER NOT NULL CHECK ("isActive" IN (0,1)),
  "lastSyncedAt" TEXT,
  "lastSyncError" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_CalendarConnection_0" ON "CalendarConnection"("userId","provider","accountEmail");
CREATE INDEX IF NOT EXISTS "native_CalendarConnection_1" ON "CalendarConnection"("userId");
CREATE INDEX IF NOT EXISTS "native_CalendarConnection_2" ON "CalendarConnection"("isActive");
CREATE TABLE IF NOT EXISTS "crm_CalendarEvents" (
  "id" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "externalId" TEXT NOT NULL,
  "iCalUID" TEXT,
  "connectionId" TEXT,
  "activityId" TEXT NOT NULL,
  "startAt" TEXT NOT NULL,
  "endAt" TEXT,
  "attendeeEmails" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "rawPayload" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("connectionId") REFERENCES "CalendarConnection"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("activityId") REFERENCES "crm_Activities"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_CalendarEvents_0" ON "crm_CalendarEvents"("source","externalId");
CREATE INDEX IF NOT EXISTS "native_crm_CalendarEvents_1" ON "crm_CalendarEvents"("iCalUID");
CREATE INDEX IF NOT EXISTS "native_crm_CalendarEvents_2" ON "crm_CalendarEvents"("activityId");
CREATE INDEX IF NOT EXISTS "native_crm_CalendarEvents_3" ON "crm_CalendarEvents"("startAt");
CREATE TABLE IF NOT EXISTS "EmailsToContacts" (
  "emailId" TEXT NOT NULL,
  "contactId" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("emailId","contactId"),
  FOREIGN KEY ("emailId") REFERENCES "Email"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("contactId") REFERENCES "crm_Contacts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_EmailsToContacts_1" ON "EmailsToContacts"("emailId");
CREATE INDEX IF NOT EXISTS "native_EmailsToContacts_2" ON "EmailsToContacts"("contactId");
CREATE TABLE IF NOT EXISTS "EmailsToAccounts" (
  "emailId" TEXT NOT NULL,
  "accountId" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("emailId","accountId"),
  FOREIGN KEY ("emailId") REFERENCES "Email"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("accountId") REFERENCES "crm_Accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_EmailsToAccounts_1" ON "EmailsToAccounts"("emailId");
CREATE INDEX IF NOT EXISTS "native_EmailsToAccounts_2" ON "EmailsToAccounts"("accountId");
CREATE TABLE IF NOT EXISTS "Session" (
  "id" TEXT NOT NULL,
  "expiresAt" TEXT NOT NULL,
  "token" TEXT NOT NULL UNIQUE,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "ipAddress" TEXT,
  "userAgent" TEXT,
  "userId" TEXT NOT NULL,
  "impersonatedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "Account" (
  "id" TEXT NOT NULL,
  "accountId" TEXT NOT NULL,
  "providerId" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "accessToken" TEXT,
  "refreshToken" TEXT,
  "idToken" TEXT,
  "accessTokenExpiresAt" TEXT,
  "refreshTokenExpiresAt" TEXT,
  "scope" TEXT,
  "password" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("userId") REFERENCES "Users"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "Verification" (
  "id" TEXT NOT NULL,
  "identifier" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  "expiresAt" TEXT NOT NULL,
  "createdAt" TEXT,
  "updatedAt" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "crm_ProductCategories" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "order" INTEGER NOT NULL,
  "isActive" INTEGER NOT NULL CHECK ("isActive" IN (0,1)),
  "source" TEXT NOT NULL CHECK ("source" IN ('CRM','EXTERNAL')),
  "externalRef" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT,
  "updatedBy" TEXT,
  "parentId" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("parentId") REFERENCES "crm_ProductCategories"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_ProductCategories_0" ON "crm_ProductCategories"("isActive");
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_ProductCategories_1" ON "crm_ProductCategories"("source","externalRef");
CREATE TABLE IF NOT EXISTS "crm_Products" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "sku" TEXT UNIQUE,
  "type" TEXT NOT NULL CHECK ("type" IN ('PRODUCT','SERVICE')),
  "status" TEXT NOT NULL CHECK ("status" IN ('DRAFT','ACTIVE','ARCHIVED')),
  "unit_price" TEXT NOT NULL,
  "unit_cost" TEXT,
  "currency" TEXT NOT NULL,
  "tax_rate" TEXT,
  "unit" TEXT,
  "is_recurring" INTEGER NOT NULL CHECK ("is_recurring" IN (0,1)),
  "billing_period" TEXT CHECK ("billing_period" IN ('MONTHLY','QUARTERLY','ANNUALLY','ONE_TIME')),
  "categoryId" TEXT,
  "source" TEXT NOT NULL CHECK ("source" IN ('CRM','EXTERNAL')),
  "externalRef" TEXT,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT,
  "updatedBy" TEXT,
  "deletedAt" TEXT,
  "deletedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("categoryId") REFERENCES "crm_ProductCategories"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_Products_0" ON "crm_Products"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Products_1" ON "crm_Products"("type");
CREATE INDEX IF NOT EXISTS "native_crm_Products_2" ON "crm_Products"("categoryId");
CREATE INDEX IF NOT EXISTS "native_crm_Products_3" ON "crm_Products"("createdBy");
CREATE INDEX IF NOT EXISTS "native_crm_Products_4" ON "crm_Products"("deletedAt");
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_Products_5" ON "crm_Products"("source","externalRef");
CREATE TABLE IF NOT EXISTS "crm_AccountProducts" (
  "id" TEXT NOT NULL,
  "accountId" TEXT NOT NULL,
  "productId" TEXT NOT NULL,
  "quantity" INTEGER NOT NULL,
  "custom_price" TEXT,
  "currency" TEXT NOT NULL,
  "snapshot_rate" TEXT,
  "status" TEXT NOT NULL CHECK ("status" IN ('ACTIVE','EXPIRED','CANCELLED','PENDING')),
  "start_date" TEXT NOT NULL,
  "end_date" TEXT,
  "renewal_date" TEXT,
  "notes" TEXT,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT NOT NULL,
  "updatedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("accountId") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_AccountProducts_0" ON "crm_AccountProducts"("accountId");
CREATE INDEX IF NOT EXISTS "native_crm_AccountProducts_1" ON "crm_AccountProducts"("productId");
CREATE INDEX IF NOT EXISTS "native_crm_AccountProducts_2" ON "crm_AccountProducts"("status");
CREATE INDEX IF NOT EXISTS "native_crm_AccountProducts_3" ON "crm_AccountProducts"("accountId","productId");
CREATE TABLE IF NOT EXISTS "crm_OpportunityLineItems" (
  "id" TEXT NOT NULL,
  "opportunityId" TEXT NOT NULL,
  "productId" TEXT,
  "name" TEXT NOT NULL,
  "sku" TEXT,
  "description" TEXT,
  "quantity" INTEGER NOT NULL,
  "unit_price" TEXT NOT NULL,
  "discount_type" TEXT NOT NULL CHECK ("discount_type" IN ('PERCENTAGE','FIXED')),
  "discount_value" TEXT NOT NULL,
  "line_total" TEXT NOT NULL,
  "currency" TEXT NOT NULL,
  "sort_order" INTEGER NOT NULL,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT NOT NULL,
  "updatedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("opportunityId") REFERENCES "crm_Opportunities"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_OpportunityLineItems_0" ON "crm_OpportunityLineItems"("opportunityId");
CREATE INDEX IF NOT EXISTS "native_crm_OpportunityLineItems_1" ON "crm_OpportunityLineItems"("productId");
CREATE TABLE IF NOT EXISTS "crm_ContractLineItems" (
  "id" TEXT NOT NULL,
  "contractId" TEXT NOT NULL,
  "productId" TEXT,
  "name" TEXT NOT NULL,
  "sku" TEXT,
  "description" TEXT,
  "quantity" INTEGER NOT NULL,
  "unit_price" TEXT NOT NULL,
  "discount_type" TEXT NOT NULL CHECK ("discount_type" IN ('PERCENTAGE','FIXED')),
  "discount_value" TEXT NOT NULL,
  "line_total" TEXT NOT NULL,
  "currency" TEXT NOT NULL,
  "sort_order" INTEGER NOT NULL,
  "__v" INTEGER NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT NOT NULL,
  "updatedBy" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("contractId") REFERENCES "crm_Contracts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_ContractLineItems_0" ON "crm_ContractLineItems"("contractId");
CREATE INDEX IF NOT EXISTS "native_crm_ContractLineItems_1" ON "crm_ContractLineItems"("productId");
CREATE TABLE IF NOT EXISTS "Invoices" (
  "id" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "createdBy" TEXT NOT NULL,
  "type" TEXT NOT NULL CHECK ("type" IN ('INVOICE','CREDIT_NOTE','PROFORMA')),
  "status" TEXT NOT NULL CHECK ("status" IN ('DRAFT','ISSUED','SENT','PARTIALLY_PAID','PAID','OVERDUE','CANCELLED','DISPUTED','REFUNDED','WRITTEN_OFF')),
  "number" TEXT,
  "numberOverridden" INTEGER NOT NULL CHECK ("numberOverridden" IN (0,1)),
  "seriesId" TEXT,
  "accountId" TEXT NOT NULL,
  "billingSnapshot" TEXT,
  "issueDate" TEXT,
  "taxableSupplyDate" TEXT,
  "dueDate" TEXT,
  "currency" TEXT NOT NULL,
  "baseCurrency" TEXT,
  "fxRateToBase" TEXT,
  "subtotal" TEXT NOT NULL,
  "discountTotal" TEXT NOT NULL,
  "vatTotal" TEXT NOT NULL,
  "grandTotal" TEXT NOT NULL,
  "paidTotal" TEXT NOT NULL,
  "balanceDue" TEXT NOT NULL,
  "bankName" TEXT,
  "bankAccount" TEXT,
  "iban" TEXT,
  "swift" TEXT,
  "variableSymbol" TEXT,
  "publicNotes" TEXT,
  "internalNotes" TEXT,
  "originalInvoiceId" TEXT,
  "pdfStorageKey" TEXT,
  "pdfGeneratedAt" TEXT,
  "search_vector" TEXT,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("seriesId") REFERENCES "Invoice_Series"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("accountId") REFERENCES "crm_Accounts"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("originalInvoiceId") REFERENCES "Invoices"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_Invoices_0" ON "Invoices"("seriesId","number");
CREATE INDEX IF NOT EXISTS "native_Invoices_1" ON "Invoices"("accountId");
CREATE INDEX IF NOT EXISTS "native_Invoices_2" ON "Invoices"("status");
CREATE INDEX IF NOT EXISTS "native_Invoices_3" ON "Invoices"("issueDate");
CREATE INDEX IF NOT EXISTS "native_Invoices_4" ON "Invoices"("dueDate");
CREATE INDEX IF NOT EXISTS "native_Invoices_5" ON "Invoices"("createdBy");
CREATE INDEX IF NOT EXISTS "native_Invoices_6" ON "Invoices"("originalInvoiceId");
CREATE TABLE IF NOT EXISTS "Invoice_LineItems" (
  "id" TEXT NOT NULL,
  "invoiceId" TEXT NOT NULL,
  "position" INTEGER NOT NULL,
  "productId" TEXT,
  "description" TEXT NOT NULL,
  "quantity" TEXT NOT NULL,
  "unitPrice" TEXT NOT NULL,
  "discountPercent" TEXT NOT NULL,
  "taxRateId" TEXT,
  "taxRateSnapshot" TEXT,
  "lineSubtotal" TEXT NOT NULL,
  "lineVat" TEXT NOT NULL,
  "lineTotal" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("invoiceId") REFERENCES "Invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("taxRateId") REFERENCES "Invoice_TaxRates"("id") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Invoice_LineItems_0" ON "Invoice_LineItems"("invoiceId");
CREATE INDEX IF NOT EXISTS "native_Invoice_LineItems_1" ON "Invoice_LineItems"("productId");
CREATE INDEX IF NOT EXISTS "native_Invoice_LineItems_2" ON "Invoice_LineItems"("taxRateId");
CREATE TABLE IF NOT EXISTS "Invoice_Payments" (
  "id" TEXT NOT NULL,
  "invoiceId" TEXT NOT NULL,
  "paidAt" TEXT NOT NULL,
  "amount" TEXT NOT NULL,
  "method" TEXT,
  "reference" TEXT,
  "note" TEXT,
  "createdBy" TEXT NOT NULL,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("invoiceId") REFERENCES "Invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("createdBy") REFERENCES "Users"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Invoice_Payments_0" ON "Invoice_Payments"("invoiceId");
CREATE TABLE IF NOT EXISTS "Invoice_Attachments" (
  "id" TEXT NOT NULL,
  "invoiceId" TEXT NOT NULL,
  "storageKey" TEXT NOT NULL,
  "filename" TEXT NOT NULL,
  "mimeType" TEXT NOT NULL,
  "size" INTEGER NOT NULL,
  "uploadedBy" TEXT NOT NULL,
  "uploadedAt" TEXT NOT NULL,
  "isPrimaryPdf" INTEGER NOT NULL CHECK ("isPrimaryPdf" IN (0,1)),
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("invoiceId") REFERENCES "Invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("uploadedBy") REFERENCES "Users"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Invoice_Attachments_0" ON "Invoice_Attachments"("invoiceId");
CREATE TABLE IF NOT EXISTS "Invoice_Activity" (
  "id" TEXT NOT NULL,
  "invoiceId" TEXT NOT NULL,
  "actorId" TEXT NOT NULL,
  "action" TEXT NOT NULL,
  "meta" TEXT,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("invoiceId") REFERENCES "Invoices"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("actorId") REFERENCES "Users"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_Invoice_Activity_0" ON "Invoice_Activity"("invoiceId");
CREATE TABLE IF NOT EXISTS "Invoice_TaxRates" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "rate" TEXT NOT NULL,
  "isDefault" INTEGER NOT NULL CHECK ("isDefault" IN (0,1)),
  "active" INTEGER NOT NULL CHECK ("active" IN (0,1)),
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Invoice_Series" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "prefixTemplate" TEXT NOT NULL,
  "resetPolicy" TEXT NOT NULL,
  "currentYear" INTEGER,
  "counter" INTEGER NOT NULL,
  "isDefault" INTEGER NOT NULL CHECK ("isDefault" IN (0,1)),
  "active" INTEGER NOT NULL CHECK ("active" IN (0,1)),
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "Invoice_Settings" (
  "id" TEXT NOT NULL,
  "baseCurrency" TEXT NOT NULL,
  "defaultSeriesId" TEXT,
  "defaultTaxRateId" TEXT,
  "defaultDueDays" INTEGER NOT NULL,
  "bankName" TEXT,
  "bankAccount" TEXT,
  "iban" TEXT,
  "swift" TEXT,
  "footerText" TEXT,
  "companyName" TEXT,
  "companyAddress" TEXT,
  "companyCity" TEXT,
  "companyZip" TEXT,
  "companyCountry" TEXT,
  "companyVatId" TEXT,
  "companyTaxId" TEXT,
  "companyRegNo" TEXT,
  "companyEmail" TEXT,
  "companyPhone" TEXT,
  "companyWebsite" TEXT,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("defaultSeriesId") REFERENCES "Invoice_Series"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("defaultTaxRateId") REFERENCES "Invoice_TaxRates"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS "InstalledPlugin" (
  "id" TEXT NOT NULL,
  "version" TEXT NOT NULL,
  "status" TEXT NOT NULL CHECK ("status" IN ('ENABLED','DISABLED')),
  "settings" TEXT NOT NULL,
  "secrets" TEXT,
  "installedAt" TEXT NOT NULL,
  "installedBy" TEXT,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE TABLE IF NOT EXISTS "PluginData" (
  "id" TEXT NOT NULL,
  "pluginId" TEXT NOT NULL,
  "entityType" TEXT NOT NULL,
  "entityId" TEXT NOT NULL,
  "key" TEXT NOT NULL,
  "value" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_PluginData_0" ON "PluginData"("pluginId","entityType","entityId","key");
CREATE INDEX IF NOT EXISTS "native_PluginData_1" ON "PluginData"("pluginId","key");
CREATE INDEX IF NOT EXISTS "native_PluginData_2" ON "PluginData"("entityType","entityId");
CREATE TABLE IF NOT EXISTS "PluginLog" (
  "id" TEXT NOT NULL,
  "pluginId" TEXT NOT NULL,
  "level" TEXT NOT NULL,
  "message" TEXT NOT NULL,
  "context" TEXT,
  "createdAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_PluginLog_0" ON "PluginLog"("pluginId","createdAt");
CREATE TABLE IF NOT EXISTS "crm_PriceLists" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "currency" TEXT NOT NULL,
  "isActive" INTEGER NOT NULL CHECK ("isActive" IN (0,1)),
  "source" TEXT NOT NULL CHECK ("source" IN ('CRM','EXTERNAL')),
  "externalRef" TEXT,
  "createdBy" TEXT,
  "updatedBy" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE NO ACTION ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_PriceLists_0" ON "crm_PriceLists"("source","externalRef");
CREATE INDEX IF NOT EXISTS "native_crm_PriceLists_1" ON "crm_PriceLists"("isActive");
CREATE TABLE IF NOT EXISTS "crm_PriceListRules" (
  "id" TEXT NOT NULL,
  "priceListId" TEXT NOT NULL,
  "appliesTo" TEXT NOT NULL CHECK ("appliesTo" IN ('ALL','CATEGORY','PRODUCT')),
  "categoryId" TEXT,
  "productId" TEXT,
  "minQuantity" TEXT NOT NULL,
  "dateStart" TEXT,
  "dateEnd" TEXT,
  "computePrice" TEXT NOT NULL CHECK ("computePrice" IN ('FIXED','PERCENTAGE','FORMULA')),
  "fixedPrice" TEXT,
  "percentPrice" TEXT,
  "base" TEXT NOT NULL CHECK ("base" IN ('LIST_PRICE','COST','PRICE_LIST')),
  "basePriceListId" TEXT,
  "priceDiscount" TEXT NOT NULL,
  "priceSurcharge" TEXT NOT NULL,
  "priceRound" TEXT,
  "priceMinMargin" TEXT,
  "priceMaxMargin" TEXT,
  "externalRef" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("priceListId") REFERENCES "crm_PriceLists"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("basePriceListId") REFERENCES "crm_PriceLists"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("categoryId") REFERENCES "crm_ProductCategories"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_PriceListRules_0" ON "crm_PriceListRules"("priceListId","appliesTo");
CREATE INDEX IF NOT EXISTS "native_crm_PriceListRules_1" ON "crm_PriceListRules"("basePriceListId");
CREATE TABLE IF NOT EXISTS "NumberSeries" (
  "id" TEXT NOT NULL,
  "scope" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "template" TEXT NOT NULL,
  "resetPolicy" TEXT NOT NULL CHECK ("resetPolicy" IN ('YEARLY','NEVER')),
  "currentYear" INTEGER,
  "counter" INTEGER NOT NULL,
  "isDefault" INTEGER NOT NULL CHECK ("isDefault" IN (0,1)),
  "active" INTEGER NOT NULL CHECK ("active" IN (0,1)),
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "native_NumberSeries_0" ON "NumberSeries"("scope","isDefault");
CREATE TABLE IF NOT EXISTS "crm_Orders" (
  "id" TEXT NOT NULL,
  "number" TEXT NOT NULL UNIQUE,
  "seriesId" TEXT NOT NULL,
  "status" TEXT NOT NULL CHECK ("status" IN ('DRAFT','PENDING_APPROVAL','READY','SENT','CONFIRMED','DELIVERED','INVOICED','PAID','CANCELLED','SYNC_FAILED')),
  "source" TEXT NOT NULL CHECK ("source" IN ('CRM','EXTERNAL')),
  "externalRef" TEXT,
  "accountId" TEXT NOT NULL,
  "contactId" TEXT,
  "ownerId" TEXT,
  "priceListId" TEXT,
  "currency" TEXT NOT NULL,
  "orderDate" TEXT NOT NULL,
  "shipping_street" TEXT,
  "shipping_city" TEXT,
  "shipping_state" TEXT,
  "shipping_postal_code" TEXT,
  "shipping_country" TEXT,
  "requestedDeliveryDate" TEXT,
  "note" TEXT,
  "subtotal" TEXT NOT NULL,
  "vatTotal" TEXT NOT NULL,
  "grandTotal" TEXT NOT NULL,
  "approvalRequestedAt" TEXT,
  "approvedAt" TEXT,
  "approvedBy" TEXT,
  "approvalNote" TEXT,
  "createdBy" TEXT,
  "updatedBy" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("seriesId") REFERENCES "NumberSeries"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("accountId") REFERENCES "crm_Accounts"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("contactId") REFERENCES "crm_Contacts"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("ownerId") REFERENCES "Users"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("priceListId") REFERENCES "crm_PriceLists"("id") ON DELETE SET NULL ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("currency") REFERENCES "Currency"("code") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX IF NOT EXISTS "native_crm_Orders_0" ON "crm_Orders"("source","externalRef");
CREATE INDEX IF NOT EXISTS "native_crm_Orders_1" ON "crm_Orders"("accountId");
CREATE INDEX IF NOT EXISTS "native_crm_Orders_2" ON "crm_Orders"("ownerId");
CREATE INDEX IF NOT EXISTS "native_crm_Orders_3" ON "crm_Orders"("status");
CREATE INDEX IF NOT EXISTS "native_crm_Orders_4" ON "crm_Orders"("createdAt");
CREATE INDEX IF NOT EXISTS "native_crm_Orders_5" ON "crm_Orders"("accountId","orderDate");
CREATE TABLE IF NOT EXISTS "crm_OrderLines" (
  "id" TEXT NOT NULL,
  "orderId" TEXT NOT NULL,
  "position" INTEGER NOT NULL,
  "productId" TEXT NOT NULL,
  "productName" TEXT NOT NULL,
  "sku" TEXT,
  "unit" TEXT,
  "quantity" TEXT NOT NULL,
  "listPrice" TEXT NOT NULL,
  "priceRuleId" TEXT,
  "unitPrice" TEXT NOT NULL,
  "unitPriceOverridden" INTEGER NOT NULL CHECK ("unitPriceOverridden" IN (0,1)),
  "vatRate" TEXT NOT NULL,
  "lineSubtotal" TEXT NOT NULL,
  "lineVat" TEXT NOT NULL,
  "lineTotal" TEXT NOT NULL,
  "_native_revision" INTEGER NOT NULL DEFAULT 1,
  "_native_search" TEXT NOT NULL DEFAULT '',
  PRIMARY KEY ("id"),
  FOREIGN KEY ("orderId") REFERENCES "crm_Orders"("id") ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY ("productId") REFERENCES "crm_Products"("id") ON DELETE RESTRICT ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS "native_crm_OrderLines_0" ON "crm_OrderLines"("orderId");
CREATE INDEX IF NOT EXISTS "native_crm_OrderLines_1" ON "crm_OrderLines"("productId");
