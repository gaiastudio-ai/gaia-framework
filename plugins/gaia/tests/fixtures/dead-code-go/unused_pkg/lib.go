package unused_pkg

import "fmt"

// UsedFunc is reachable from main.
func UsedFunc() { fmt.Println("used") }

// UnusedFunc has no callers — deadcode reports it.
func UnusedFunc() { fmt.Println("dead") }
