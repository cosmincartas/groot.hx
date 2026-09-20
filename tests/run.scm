;; Test runner entry point suitable for CI: steel tests/run.scm.
;; Every suite runs; the harness then reports totals and fails on any failure.
(require "core-test.scm")
(require "fs-test.scm")
(require "tree-test.scm")
(require "search-test.scm")
(require "integration-test.scm")
(require "harness.scm")
(harness-report!)
