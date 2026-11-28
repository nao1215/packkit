set shell := ["sh", "-cu"]

# Make the mise-managed toolchain (erlang / gleam / rebar / node)
# visible to every recipe even when the invoking shell has not run
# `mise activate`.
export PATH := shell('. scripts/lib/mise_bootstrap.sh; printf %s "$PATH"')

default:
  @just --list

deps:
  gleam deps download

format:
  gleam format src/ test/

format-check:
  gleam format --check src/ test/

lint:
  gleam run -m glinter

typecheck:
  gleam check

build:
  gleam build --warnings-as-errors

build-erlang:
  gleam build --warnings-as-errors --target erlang

build-javascript:
  gleam build --warnings-as-errors --target javascript

build-all-targets: build-erlang build-javascript

test:
  gleam test

test-erlang:
  gleam test --target erlang

test-javascript:
  gleam test --target javascript

test-all-targets: test-erlang test-javascript

docs:
  gleam docs build

check: clean
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter
  gleam build --warnings-as-errors
  gleam test

ci: deps check build-javascript test-javascript

all: clean deps
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter
  gleam build --warnings-as-errors --target erlang
  gleam build --warnings-as-errors --target javascript
  gleam test --target erlang
  gleam test --target javascript
  gleam docs build
  @echo ""
  @echo "All checks passed."

# Mutation testing of every module, failing on survivors the baseline lacks.
# Slow (about 3100 mutants): CI runs it weekly in 16 parts.
# The Brotli dictionary is generated data, so it is not mutated.
mutation workers="8":
  gleam run -m metamon/mutation -- run --workers {{workers}} --exclude src/packkit/internal/brotli_dictionary.gleam
  gleam run -m metamon/mutation -- gate

# Record build/mutation/results.json as the baseline and refresh doc/testing.md
coverage:
  gleam run -m metamon/mutation -- coverage

mutation-record:
  gleam run -m metamon/mutation -- baseline

clean:
  gleam clean
