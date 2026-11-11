package auth

// ok: always-on-fake-sign-in
func CreateAuthClient(cfg Config) AuthClient {
	if cfg.UseFake {
		return FakeAuthClient(cfg)
	}
	return RealAuthClient(cfg)
}
