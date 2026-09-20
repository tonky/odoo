set positional-arguments

default:
    @just --list

# Run base tests with loopback Postgres
test-base:
    python3 odoo-bin -d test_odoo -i base --test-enable --stop-after-init

# Run enact affected components
test-affected:
    enact run --keep-going

# Fast monorepo linting (Ruff + Oxlint)
lint:
    enve run -- ruff check
    enve run -- oxlint -c oxlint.json

# Run hermetic pre-commit checks on staged files
pre-commit:
    ./setup/git-hooks/pre-commit

# Install git pre-commit hook
install-hooks:
    cp setup/git-hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit

