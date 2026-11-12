package db

func good(db *sql.DB, id int) {
	// ok: sql-built-with-sprintf
	db.Query("SELECT * FROM users WHERE id = $1", id)
}
