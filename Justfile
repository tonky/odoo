set positional-arguments

default:
    @just --list

# Run base tests with loopback Postgres (the repository's Python, as the pipeline runs them)
test-base:
    enve run -- bash helpers/odoo-runner.sh -d test_odoo -i base --test-enable --stop-after-init

# Run enact affected components
test-affected:
    enact run --keep-going

# Fast monorepo linting (Ruff + Oxlint)
lint:
    # Advisory as in the jobs (helpers/odoo-lint.sh): the tree has ~37k findings under ruff.toml.
    enve run -- ruff check --exit-zero --quiet
    enve run -- oxlint -c oxlint.json

# Run hermetic pre-commit checks on staged files
pre-commit:
    ./setup/git-hooks/pre-commit

# Install git pre-commit hook
install-hooks:
    cp setup/git-hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit

