# Explicit identities must create no GitHub request, even if the API is unavailable.
mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 503
      response_body = "{}"
    }
  }
}
variables {
  tenant = { provider = "github_app", subject_id = "123" }
}
run "supplied_identity_without_lookup" {
  command = apply
  assert {
    condition     = output.identity == var.tenant && length(data.http.account) == 0
    error_message = "The supplied provider/subject pair must be recorded without a lookup."
  }
}

# Neither a missing identity nor conflicting input forms may establish trust.
run "missing_identity" {
  command         = plan
  variables { tenant = null }
  expect_failures = [terraform_data.identity]
}
run "conflicting_identity_inputs" {
  command = plan
  variables { namespace = "github_app/acme" }
  expect_failures = [terraform_data.identity]
}

# Supplied identities must use canonical IDs; namespace-shaped values are invalid.
run "reject_supplied_login" {
  command = plan
  variables { tenant = { provider = "github_app", subject_id = "acme" } }
  expect_failures = [var.tenant]
}
run "reject_supplied_zero" {
  command = plan
  variables { tenant = { provider = "github_app", subject_id = "0" } }
  expect_failures = [var.tenant]
}
run "reject_supplied_leading_zero" {
  command = plan
  variables { tenant = { provider = "github_app", subject_id = "0123" } }
  expect_failures = [var.tenant]
}
run "reject_supplied_empty_subject" {
  command = plan
  variables { tenant = { provider = "github_app", subject_id = "" } }
  expect_failures = [var.tenant]
}
run "reject_supplied_unknown_provider" {
  command = plan
  variables { tenant = { provider = "other", subject_id = "123" } }
  expect_failures = [var.tenant]
}

# Direct input changes cannot silently replace the pinned provider or subject.
run "changed_supplied_subject_requires_rebind" {
  command = plan
  variables { tenant = { provider = "github_app", subject_id = "456" } }
  expect_failures = [output.identity]
}
run "changed_supplied_provider_requires_rebind" {
  command = plan
  variables { tenant = { provider = "github_oauth", subject_id = "123" } }
  expect_failures = [output.identity]
}
run "supplied_owner_remains_pinned" {
  command = plan
  assert {
    condition     = output.identity == var.tenant
    error_message = "Rejected edits must preserve the originally supplied identity."
  }
}

# Explicit replacement records the new supplied owner without consulting GitHub.
run "rebind_supplied_identity" {
  command = apply
  plan_options { replace = [terraform_data.identity] }
  variables { tenant = { provider = "github_app", subject_id = "456" } }
  assert {
    condition     = output.identity == var.tenant && length(data.http.account) == 0
    error_message = "An explicit rebind must pin exactly the supplied identity without a lookup."
  }
}
run "supplied_prior_owner_requires_rebind" {
  command         = plan
  expect_failures = [output.identity]
}

# Input forms may be switched when they still name the same pinned owner.
run "switch_to_matching_locator" {
  command = apply
  variables {
    tenant    = null
    namespace = "github_app/acme"
  }
  override_data {
    target = data.http.account[0]
    values = {
      status_code   = 200
      response_body = "{\"id\":456,\"type\":\"Organization\"}"
    }
  }
  assert {
    condition     = output.identity == { provider = "github_app", subject_id = "456" }
    error_message = "A locator for the pinned account must preserve its supplied owner."
  }
}
run "switch_to_matching_supplied_identity" {
  command = apply
  variables { tenant = { provider = "github_app", subject_id = "456" } }
  assert {
    condition     = output.identity == var.tenant && length(data.http.account) == 0
    error_message = "Switching away from lookup must retain the same pinned owner and remove the request."
  }
}
