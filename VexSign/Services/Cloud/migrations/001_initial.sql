-- Applied atomically by src/migrate.ts. No plaintext credentials or public S3 ACLs.
CREATE TABLE IF NOT EXISTS assets (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('ipa','p12','provision')),
    object_key text NOT NULL UNIQUE,
    sha256 char(64) NOT NULL,
    bytes bigint NOT NULL CHECK (bytes > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, owner)
);
CREATE INDEX IF NOT EXISTS assets_owner ON assets(owner, created_at);
CREATE TABLE IF NOT EXISTS jobs (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('sign','check-cert')),
    idempotency_key uuid NOT NULL,
    request_hash char(64) NOT NULL,
    state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','completed','failed')),
    ipa_id uuid,
    p12_id uuid NOT NULL,
    provision_id uuid NOT NULL,
    sealed_password text,
    webhook text,
    output_key text,
    output_sha256 char(64),
    result jsonb,
    error_code text,
    published_at timestamptz,
    started_at timestamptz,
    finished_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner, idempotency_key),
    FOREIGN KEY (ipa_id, owner) REFERENCES assets(id, owner),
    FOREIGN KEY (p12_id, owner) REFERENCES assets(id, owner),
    FOREIGN KEY (provision_id, owner) REFERENCES assets(id, owner)
);
CREATE INDEX IF NOT EXISTS jobs_owner ON jobs(owner, created_at DESC);
CREATE INDEX IF NOT EXISTS jobs_outbox ON jobs(created_at) WHERE published_at IS NULL AND state = 'queued';
CREATE TABLE IF NOT EXISTS webhook_deliveries (
    job_id uuid PRIMARY KEY REFERENCES jobs(id),
    owner text NOT NULL,
    url text NOT NULL,
    payload jsonb NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz
);
CREATE TABLE IF NOT EXISTS audit_logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner text NOT NULL,
    action text NOT NULL,
    resource_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- Deliberately exclude IPs, JWTs, passwords, private keys, and capability links.
