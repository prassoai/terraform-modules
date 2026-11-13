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
  namespace = "github_app/acme"
}
run "immutable_account" {
  command = apply
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "123" }
    error_message = "Trust must use the immutable account ID, not the input login."
  }
}
run "renamed_account" {
  command = apply
  variables { namespace = "github_app/acme-renamed" }
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "123" }
    error_message = "A rename must preserve trust in the same account."
  }
}
# A refreshed login cannot select another trusted owner.
run "reassigned_login" {
  command = plan
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  expect_failures = [output.identity]
}
run "invalid_locator" {
  command = plan
  variables { namespace = "platform:github_app/acme" }
  expect_failures = [var.namespace]
}
run "account_lookup_failed" {
  command = plan
  override_data {
    target = data.http.account[0]
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
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":0,\"type\":\"Organization\"}"
    }
  }
  expect_failures = [output.identity]
}

# Digits in a namespace remain a login, never an implicit subject ID.
run "numeric_login_is_resolved" {
  command = plan
  plan_options { replace = [terraform_data.identity] }
  variables { namespace = "github_app/123" }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  assert {
    condition     = output.identity.subject_id == "456"
    error_message = "A numeric login must be resolved instead of interpreted as an immutable ID."
  }
}

# The provider is retained in the canonical record for personal GitHub tenants.
run "personal_account" {
  command = plan
  plan_options { replace = [terraform_data.identity] }
  variables { namespace = "github_oauth/octocat" }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":789,\"type\":\"User\"}"
    }
  }
  assert {
    condition     = output.identity == { provider = "github_oauth", subject_id = "789" }
    error_message = "Personal tenants must record both provider and immutable subject ID."
  }
}

# An edited locator cannot select another account behind an established binding.
run "changed_locator_cannot_redirect_trust" {
  command = plan
  variables { namespace = "github_app/another-account" }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  expect_failures = [output.identity]
}

# Provider and subject together identify the owner; a provider edit cannot rebind.
run "changed_provider_cannot_redirect_trust" {
  command = plan
  variables { namespace = "github_oauth/acme" }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":123,\"type\":\"User\"}"
    }
  }
  expect_failures = [output.identity]
}

# Failed refreshes leave the original canonical owner authoritative.
run "original_owner_remains_pinned" {
  command = plan
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "123" }
    error_message = "Rejected locator changes must not update the pinned identity."
  }
}

# Only explicit replacement authorizes a deliberate binding to a new owner.
run "explicit_rebind" {
  command = apply
  plan_options { replace = [terraform_data.identity] }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "456" }
    error_message = "An explicit rebind must record the operator-selected owner."
  }
}

# Rebinding changes the authoritative owner; returning the prior account is denied.
run "prior_owner_requires_another_rebind" {
  command         = plan
  expect_failures = [output.identity]
}

# Ordinary refreshes of the explicitly rebound account retain its new pin.
run "new_owner_remains_pinned" {
  command = plan
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "456" }
    error_message = "The rebound owner must remain authoritative after replacement."
  }
}
