package replay

// Odoo ERP test services and environment, adapted for replay.
devEnv: {
    "description": "Odoo Modular ERP (Python + Rootless PostgreSQL on Loopback)",
    "disabledServices": [],
    "environment": {
        "PGHOST": "127.0.0.1",
        "PGPORT": "5432",
        "PGUSER": "odoo",
        "PGDATABASE": "test_odoo",
        "PYTHONPATH": ".",
        "PYTHONNOUSERSITE": "1",
        "TEST": "1"
    },
    "gitHooks": {
        "clippy": false,
        "cue_fmt": false,
        "custom": {},
        "golangci_lint": false,
        "prettier": false,
        "ruff": false
    },
    "hosts": {
        "db": "127.0.0.1"
    },
    "name": "odoo-replay",
    "ports": [],
    "services": {
        "db": {
            "command": "postgres -D /tmp/odoo_enve_postgres -k /tmp -h 127.0.0.1 -p 5432 -c fsync=off -c synchronous_commit=off -c full_page_writes=off -N 250",
            "dataDir": "/tmp/odoo_enve_postgres",
            "database": "test_odoo",
            "template": "test_odoo_template",
            "dependsOn": [],
            "directory": ".",
            "enabled": true,
            "environment": {
                "PGDATA": "/tmp/odoo_enve_postgres",
                "PGDATABASE": "test_odoo",
                "PGHOST": "127.0.0.1",
                "PGPORT": "5432",
                "PGUSER": "odoo",
                "PGTEMPLATE": "test_odoo_template"
            },
            "environmentPolicy": {
                "mode": "inherit"
            },
            "external": false,
            "files": {},
            "healthCheck": {
                "intervalMs": 10000,
                "port": 5432,
                "retries": 15,
                "timeout": "10000ms",
                "timeoutMs": 10000
            },
            "host": "127.0.0.1",
            "isolation": "auto",
            "lifecycle": {
                "init": [
                    "bash setup/ci/init-postgres.sh"
                ],
                "preStart": [
                    "bash setup/ci/init-postgres.sh"
                ],
                "postStart": [
                    "bash setup/ci/post-start-postgres.sh"
                ]
            },
            "name": "db",
            "port": 5432,
            "readinessProbe": {
                "initialDelayMs": 0,
                "port": 5432,
                "timeout": "15000ms",
                "timeoutMs": 15000
            },
            "resources": {},
            "restartPolicy": "on-failure",
            "socketDir": "/tmp",
            "timeout": "15000ms"
        }
    },
    "tools": [
        "oxlint",
        "ruff",
        "uv",
        "postgresql",
        {
            "pname": "python3",
            "version": "3.12"
        },
    ]
}
