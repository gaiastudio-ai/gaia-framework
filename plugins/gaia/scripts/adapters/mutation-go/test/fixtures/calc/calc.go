package calc

// Add returns the sum of a and b when a is positive,
// otherwise returns b unchanged.
func Add(a, b int) int {
	if a > 0 {
		return a + b
	}
	return b
}
