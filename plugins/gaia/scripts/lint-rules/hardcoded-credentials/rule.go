package config

import "os"

// ruleid: hardcoded-credentials
var password = "super_secret_value_abc123" // lint-pack:allow hardcoded-credentials

// ok: hardcoded-credentials
var dbPassword = os.Getenv("DB_PASSWORD")
