package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
)

// hostPolicy is the host's pinned descriptor plus its bindings, written by the
// app-deployments module for each Project release.
type hostPolicy struct {
	Descriptor  json.RawMessage `json:"descriptor"`
	ManagedJobs []string        `json:"managedJobs"`
	Bindings    struct {
		Parameters map[string]json.RawMessage            `json:"parameters"`
		Secrets    []string                              `json:"secrets"`
		Resources  map[string]map[string]json.RawMessage `json:"resources"`
	} `json:"bindings"`
}

// releaseDescriptor is the part of a normalized descriptor that release
// planning reads. Other sections are ignored.
type releaseDescriptor struct {
	SchemaVersion int                            `json:"schemaVersion"`
	Project       string                         `json:"project"`
	Parameters    map[string]parameterDefinition `json:"parameters"`
	Secrets       map[string]struct {
		Required    bool   `json:"required"`
		Description string `json:"description"`
	} `json:"secrets"`
	Requirements map[string]requirement `json:"requirements"`
	Release      *struct {
		Backend              string                `json:"backend"`
		ActivationExecutable *string               `json:"activationExecutable"`
		Health               json.RawMessage       `json:"health"`
		Commands             map[string]entryPoint `json:"commands"`
		MaintenanceJobs      map[string]entryPoint `json:"maintenanceJobs"`
		PreDeployTasks       map[string]struct {
			Action      string   `json:"action"`
			DependsOn   []string `json:"dependsOn"`
			FailureMode string   `json:"failureMode"`
			Secrets     []string `json:"secrets"`
			TimeoutSec  int64    `json:"timeoutSec"`
		} `json:"preDeployTasks"`
	} `json:"release"`
}

type entryPoint struct {
	Action  string   `json:"action"`
	Secrets []string `json:"secrets"`
}

type bound[V any] struct {
	values  map[string]V
	reasons []string
}

func decodeLenient(data []byte, label string, target any) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		fail(exitData, "%s: %v", label, err)
	}
}

// releaseContract selects the release topology that must match the host's
// compiled configuration. Service activation hooks may change freely.
func releaseContract(data []byte, label string) map[string]any {
	var raw struct {
		SchemaVersion json.Number    `json:"schemaVersion"`
		Project       string         `json:"project"`
		Release       map[string]any `json:"release"`
	}
	decodeLenient(data, label, &raw)
	if raw.Release == nil {
		fail(exitData, "%s: descriptor does not define a Release", label)
	}
	release := map[string]any{}
	fields := []string{"backend", "action", "executable", "stateDirectories", "ingress", "ociAuxiliaries"}
	if raw.Release["backend"] == "static" {
		fields = append(fields, "activationExecutable")
	}
	for _, field := range fields {
		release[field] = raw.Release[field]
	}
	return map[string]any{"schemaVersion": raw.SchemaVersion, "project": raw.Project, "release": release}
}

// taskOrder runs ready tasks in sorted rounds; tasks left over form a cycle.
func taskOrder(dependencies map[string][]string) (order []string, remaining []string) {
	remaining = sortedKeys(dependencies)
	for len(remaining) > 0 {
		done := map[string]bool{}
		for _, name := range order {
			done[name] = true
		}
		ready, blocked := []string{}, []string{}
		for _, name := range remaining {
			satisfied := true
			for _, dependency := range dependencies[name] {
				satisfied = satisfied && done[dependency]
			}
			if satisfied {
				ready = append(ready, name)
			} else {
				blocked = append(blocked, name)
			}
		}
		if len(ready) == 0 {
			break
		}
		order, remaining = append(order, ready...), blocked
	}
	return order, remaining
}

func planRelease(policy hostPolicy, candidateData []byte) map[string]any {
	var candidate releaseDescriptor
	decodeLenient(candidateData, "candidate descriptor", &candidate)
	if candidate.Release == nil {
		fail(exitData, "candidate descriptor does not define a Release")
	}
	release := candidate.Release
	reasons := []string{}

	expectedContract := releaseContract(policy.Descriptor, "host descriptor")
	candidateContract := releaseContract(candidateData, "candidate descriptor")
	if !reflect.DeepEqual(expectedContract, candidateContract) {
		reasons = append(reasons, "Release topology differs from the host-compatible contract")
	}

	// Only secrets required by release-realized requirements need bindings.
	releaseRequirements := map[string]requirement{}
	for name, value := range candidate.Requirements {
		if value.appliesTo("release") {
			releaseRequirements[name] = value
		}
	}
	declaredSecrets := map[string]bool{}
	for name := range candidate.Secrets {
		if _, ok := candidate.Requirements[name]; !ok {
			declaredSecrets[name] = true
		} else if _, ok := releaseRequirements[name]; ok {
			declaredSecrets[name] = true
		}
	}

	tasks := map[string]any{}
	dependencies := map[string][]string{}
	for _, name := range sortedKeys(release.PreDeployTasks) {
		task := release.PreDeployTasks[name]
		tasks[name] = task
		dependencies[name] = task.DependsOn
		for _, dependency := range task.DependsOn {
			if _, ok := release.PreDeployTasks[dependency]; !ok {
				reasons = append(reasons, "pre-deploy task "+name+" depends on undeclared task: "+dependency)
			}
		}
	}
	for _, name := range sortedKeys(release.PreDeployTasks) {
		for _, secret := range release.PreDeployTasks[name].Secrets {
			if !declaredSecrets[secret] {
				reasons = append(reasons, "pre-deploy task "+name+" references undeclared Secret: "+secret)
			}
		}
	}
	jobs := map[string]entryPoint{}
	for _, name := range policy.ManagedJobs {
		job, ok := release.MaintenanceJobs[name]
		if !ok {
			reasons = append(reasons, "host-managed maintenance job is not declared by the candidate: "+name)
			continue
		}
		jobs[name] = job
	}
	for _, name := range sortedKeys(jobs) {
		for _, secret := range jobs[name].Secrets {
			if !declaredSecrets[secret] {
				reasons = append(reasons, "maintenance job "+name+" references undeclared Secret: "+secret)
			}
		}
	}
	for _, name := range sortedKeys(release.Commands) {
		for _, secret := range release.Commands[name].Secrets {
			if !declaredSecrets[secret] {
				reasons = append(reasons, "command "+name+" references undeclared Secret: "+secret)
			}
		}
	}
	order, cyclic := taskOrder(dependencies)
	if len(cyclic) > 0 {
		reasons = append(reasons, "pre-deploy task dependency graph contains a cycle")
	}

	parameters := bound[any]{values: map[string]any{}}
	for _, name := range sortedKeys(candidate.Parameters) {
		definition := candidate.Parameters[name]
		if data, ok := policy.Bindings.Parameters[name]; ok {
			value := decodeValue(data)
			if parameterMatches(value, definition.Type) {
				parameters.values[name] = value
			} else {
				parameters.reasons = append(parameters.reasons, "parameter "+name+" binding does not match type "+definition.Type)
			}
		} else if definition.hasDefault() {
			parameters.values[name] = decodeValue(definition.Default)
		} else if definition.Required {
			parameters.reasons = append(parameters.reasons, "missing required parameter binding: "+name)
		} else {
			parameters.values[name] = nil
		}
	}

	boundSecrets := map[string]bool{}
	for _, name := range policy.Bindings.Secrets {
		boundSecrets[name] = true
	}
	secrets := bound[string]{values: map[string]string{}}
	for _, name := range sortedKeys(candidate.Secrets) {
		if !declaredSecrets[name] {
			continue
		}
		if boundSecrets[name] {
			secrets.values[name] = name
		} else if candidate.Secrets[name].Required {
			secrets.reasons = append(secrets.reasons, "missing required Secret binding: "+name)
		}
	}

	resources := bound[map[string]any]{values: map[string]map[string]any{}}
	for _, name := range sortedKeys(releaseRequirements) {
		value := releaseRequirements[name]
		raw, present := policy.Bindings.Resources[name]
		if !present {
			if value.Required {
				resources.reasons = append(resources.reasons, "missing required resource binding: "+name)
			}
			continue
		}
		binding := map[string]any{}
		for field, data := range raw {
			binding[field] = decodeValue(data)
		}
		problem := bindingProblem(value, binding, func(credential string) bool {
			_, ok := secrets.values[credential]
			return ok
		})
		if problem != "" {
			resources.reasons = append(resources.reasons, "resource "+name+" "+problem)
			continue
		}
		resources.values[name] = binding
	}

	reasons = append(reasons, parameters.reasons...)
	reasons = append(reasons, secrets.reasons...)
	reasons = append(reasons, resources.reasons...)
	commands := release.Commands
	if commands == nil {
		commands = map[string]entryPoint{}
	}
	return map[string]any{
		"compatible": len(reasons) == 0,
		"reasons":    reasons,
		"parameters": parameters.values,
		"secrets":    secrets.values,
		"bindings":   resources.values,
		"releasePlan": map[string]any{
			"activationExecutable": release.ActivationExecutable,
			"commands":             commands,
			"health":               release.Health,
			"maintenanceJobs":      jobs,
			"preDeployTasks":       tasks,
			"preDeployOrder":       append([]string{}, order...),
		},
		"expectedContract":  expectedContract,
		"candidateContract": candidateContract,
	}
}

func printPlan(hostPath string, candidatePath string) int {
	var policy hostPolicy
	loadFile(hostPath, "host release policy", &policy)
	candidate, err := os.ReadFile(candidatePath)
	if err != nil {
		fail(exitData, "candidate descriptor %s: %v", candidatePath, err)
	}
	encoded, err := json.Marshal(planRelease(policy, candidate))
	if err != nil {
		fail(exitData, "could not encode release plan: %v", err)
	}
	fmt.Println(string(encoded))
	return 0
}
