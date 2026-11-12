package config

import "os"

// ok: hardcoded-credentials
var password = os.Getenv("DB_PASSWORD")
