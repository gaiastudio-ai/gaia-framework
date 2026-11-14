package calc

import "testing"

func TestAddPositive(t *testing.T) {
	if got := Add(1, 2); got != 3 {
		t.Fatalf("Add(1, 2) = %d, want 3", got)
	}
}

func TestAddZero(t *testing.T) {
	if got := Add(0, 5); got != 5 {
		t.Fatalf("Add(0, 5) = %d, want 5", got)
	}
}
