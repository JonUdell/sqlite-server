# sqlite-server

A lightweight httpd that:

- serves static files

- provides a /query endpoint that sends sql statements to a /query endpoint wired to a local sqlite db, data.db

- provides a /cors endpoint so js clients can use apis that don't support cors

