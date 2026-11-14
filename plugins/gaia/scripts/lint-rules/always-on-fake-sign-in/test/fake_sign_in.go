package auth

// ruleid: always-on-fake-sign-in
func CreateAuthClient(cfg Config) AuthClient {
	return FakeAuthClient(cfg)
}
