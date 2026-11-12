package db

import "fmt"

func bad(db *sql.DB, table string) {
	// ruleid: sql-built-with-sprintf
	query := fmt.Sprintf("SELECT * FROM %s WHERE id = 1", table)
	db.Query(query)
}

func good(db *sql.DB, id int) {
	// ok: sql-built-with-sprintf
	db.Query("SELECT * FROM users WHERE id = $1", id)
}
