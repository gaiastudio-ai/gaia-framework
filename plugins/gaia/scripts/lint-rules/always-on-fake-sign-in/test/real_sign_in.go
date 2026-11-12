package auth

// ok: always-on-fake-sign-in
func BuildLoginHandler(cfg Config) AuthClient {
	return RealAuthClient(cfg)
}
