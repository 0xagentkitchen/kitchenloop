# Example: Web API Project

This example shows how to configure KitchenLoop for a REST API with
role-based access control.

## Project: taskapi

A task management API with endpoints for users, tasks, and teams. It uses
role-based auth (admin, manager, member) and needs to handle various payload
conditions correctly.

## Spec Surface

The spec surface has 3 dimensions:

- **endpoints**: 13 REST endpoints (CRUD for users, tasks, teams, plus health)
- **auth_roles**: admin, manager, member, anonymous, expired_token, invalid_token
- **payload_conditions**: valid, missing_required, extra_fields, malformed_json, empty_body

Total combinations: 390, minus blocked: ~210 testable.

## Key Design Decisions

**Post-merge review enabled**: This config uses CodeRabbit for post-merge
review in addition to Claude for pre-merge triage. API projects benefit from
a second pair of eyes on security-sensitive auth logic.

**require_test_addition: true**: Every iteration must add at least one test.
API projects tend to have many untested auth/payload combinations, so pure
test additions are always valuable.

**JSON logging**: Enabled for structured log output, making it easier to parse
and aggregate results across iterations.

**docker compose for build**: The `build_command` starts the API service in
Docker before tests run. Tests hit the running API.

## Blocked Combinations

- Health endpoint is public (no auth edge cases)
- GET and DELETE have no request body (no payload conditions)
- PUT endpoints always need a body (empty_body blocked)

## Usage

```bash
# Copy this config to your API project
cp kitchenloop.yaml /path/to/your-api-project/

# Edit to match your endpoints and auth roles
$EDITOR /path/to/your-api-project/kitchenloop.yaml

# Run
kitchenloop.sh --once
```

## What to Customize

1. **endpoints**: Replace with your actual API endpoints
2. **auth_roles**: Replace with your actual roles and auth failure modes
3. **payload_conditions**: Add project-specific validation edge cases
4. **build_command**: Update for your service startup (docker, uvicorn, etc.)
5. **test_command**: Point to your test runner with appropriate markers
