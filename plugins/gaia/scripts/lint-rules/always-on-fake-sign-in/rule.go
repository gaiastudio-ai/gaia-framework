package auth

// ruleid: always-on-fake-sign-in
func CreateAuthClient(cfg Config) AuthClient {
	return FakeAuthClient(cfg)
}

// ok: always-on-fake-sign-in
func BuildLoginHandler(cfg Config) AuthClient {
	return RealAuthClient(cfg)
}
