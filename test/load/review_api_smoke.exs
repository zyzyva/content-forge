# Manual load-smoke runner for the Review API + publishing endpoints.
#
# Not part of CI. Invoke explicitly from a dev / load env:
#
#     MIX_ENV=dev mix run test/load/review_api_smoke.exs
#
# The full option surface lives on `ContentForge.LoadSmoke.ReviewApi`
# along with environment-variable config (see module docs).

ContentForge.LoadSmoke.ReviewApi.run()
