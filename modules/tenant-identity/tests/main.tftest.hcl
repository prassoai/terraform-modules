# Resolve a readable locator to the immutable ID used by both trust modules.
mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"id\":123,\"type\":\"Organization\"}"
    }
  }
}
variables {
  tenant = "github_app/acme"
}
run "immutable_account" {
  command = plan
  assert {
    condition     = output.tenant_id == "github_app/123"
    error_message = "Trust must use the immutable account ID, not the input login."
  }
}
run "renamed_account" {
  command = plan
  variables { tenant = "github_app/acme-renamed" }
  assert {
    condition     = output.tenant_id == "github_app/123"
    error_message = "A rename must preserve trust in the same account."
  }
}
run "reassigned_login" {
  command = plan
  override_data {
    target = data.http.account
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  assert {
    condition     = output.tenant_id == "github_app/456"
    error_message = "A reused login must resolve to its new account, requiring an explicit trust plan change."
  }
}
run "invalid_locator" {
  command = plan
  variables { tenant = "platform:github_app/acme" }
  expect_failures = [var.tenant]
}
run "account_lookup_failed" {
  command = plan
  override_data {
    target = data.http.account
    values = {
      status_code   = 404
      response_body = "{\"message\":\"Not Found\"}"
    }
  }
  expect_failures = [data.http.account]
}
run "invalid_subject" {
  command = plan
  override_data {
    target = data.http.account
    values = {
      status_code   = 200
      response_body = "{\"id\":0,\"type\":\"Organization\"}"
    }
  }
  expect_failures = [output.tenant_id]
}
