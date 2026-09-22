package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestTaskOrderRunsReadyTasksInSortedRounds(t *testing.T) {
	order, cyclic := taskOrder(map[string][]string{
		"migrate": {"backup"},
		"backup":  {},
		"warm":    {},
		"loop-a":  {"loop-b"},
		"loop-b":  {"loop-a"},
	})
	if want := []string{"backup", "warm", "migrate"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	if want := []string{"loop-a", "loop-b"}; !reflect.DeepEqual(cyclic, want) {
		t.Fatalf("cyclic = %v, want %v", cyclic, want)
	}
}

const plannedDescriptor = `{
  "schemaVersion": 4, "project": "demo",
  "parameters": {"size": {"type": "integer", "required": false, "description": "", "default": 4}},
  "secrets": {"token": {"required": true, "description": ""}, "devOnly": {"required": true, "description": ""}},
  "requirements": {
    "token": {"kind": "secret", "required": true, "description": "", "realizations": ["release"], "generate": null},
    "devOnly": {"kind": "secret", "required": true, "description": "", "realizations": ["development"], "generate": null}
  },
  "release": {
    "backend": "service", "action": "web", "executable": "project-release-runtime",
    "activationExecutable": %s, "stateDirectories": [], "ingress": {}, "ociAuxiliaries": {},
    "health": {"paths": ["/"], "intervalSec": 2, "requestTimeoutSec": 5, "startupTimeoutSec": 60},
    "commands": {}, "maintenanceJobs": {},
    "preDeployTasks": {"migrate": {"action": "migrate", "dependsOn": [], "failureMode": "fail", "secrets": ["token"], "timeoutSec": 900}}
  }
}`

func descriptorWithActivation(activation string) []byte {
	return []byte(strings.Replace(plannedDescriptor, "%s", activation, 1))
}

func TestPlanReleaseAllowsServiceActivationChangesAndBindsReleaseSecrets(t *testing.T) {
	policy := hostPolicy{Descriptor: descriptorWithActivation("null")}
	policy.Bindings.Secrets = []string{"token"}
	policy.Bindings.Resources = map[string]map[string]json.RawMessage{
		"token": {"kind": json.RawMessage(`"secret"`), "credential": json.RawMessage(`"token"`)},
	}
	plan := planRelease(policy, descriptorWithActivation(`"activate"`))
	if plan["compatible"] != true {
		t.Fatalf("plan is incompatible: %v", plan["reasons"])
	}
	if secrets := plan["secrets"].(map[string]string); !reflect.DeepEqual(secrets, map[string]string{"token": "token"}) {
		t.Fatalf("secrets = %v", secrets)
	}
	parameters, _ := json.Marshal(plan["parameters"])
	if string(parameters) != `{"size":4}` {
		t.Fatalf("parameters = %s", parameters)
	}
}

func TestPlanReleaseReportsMissingSecretBinding(t *testing.T) {
	policy := hostPolicy{Descriptor: descriptorWithActivation("null")}
	plan := planRelease(policy, descriptorWithActivation("null"))
	want := []string{"missing required Secret binding: token", "missing required resource binding: token"}
	if !reflect.DeepEqual(plan["reasons"], want) {
		t.Fatalf("reasons = %v, want %v", plan["reasons"], want)
	}
}
