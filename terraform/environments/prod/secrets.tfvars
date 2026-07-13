# ─────────────────────────────────────────────────────────────────────────────
# secrets.tfvars — NEVER COMMIT THIS FILE
#
# This file is listed in terraform/.gitignore. If you ever see it appear in
# `git status` or `git diff`, stop and run:
#   git rm --cached environments/prod/secrets.tfvars
# before staging anything else.
#
# Generate values:
#   db_password:        openssl rand -base64 24
#   redis_auth_token:   openssl rand -hex 32   (must be 16-128 chars)
#   jwt_access_secret:  openssl rand -hex 32   (min 32 chars)
#   jwt_refresh_secret: openssl rand -hex 32   (min 32 chars)
#   cookie_secret:      openssl rand -hex 32
#   metrics_secret:     openssl rand -hex 16   (min 16 chars)
#   grafana_password:   choose manually
# ─────────────────────────────────────────────────────────────────────────────

db_password        = "koNJwU9cr7Lkv+U4vVw7Y9QI2B3dFnHr5iA2xUdlm0K5jNMX6ywGdICAGGpIdmzW"
redis_auth_token   = "64ed4a903e5b00ba115ebe6e78d3e0896e299c9abb252027786ac85d490be4b7"
jwt_access_secret  = "kJIGY0RcJAD6b2jTKA3Tk50hfpGoiRCxfWZ2twi0M0IAmWzrYm0+f3w+od9azDK9"
jwt_refresh_secret = "B6Yswo7zCfjibTMUH1366Es2gV83ubAlVazgGzhMiESiLip1QP819KsqJ6U74p4X"
cookie_secret      = "HYRfLNMD8U+QzApbhGkMb3BetEbDPo8kcHRbHR+7P3JE6nj0YEs3ZN0Sw1gkJ0IF"
metrics_secret     = "4361310ddfaf8ef2511ee7d3ef9d52b72b8c52cd45e399a1f6e2dab0a70c9114"
grafana_password   = "admin"
