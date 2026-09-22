package main

import (
	"bytes"
	"encoding/json"
	"regexp"
)

var (
	namePattern        = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	credentialPattern  = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	revisionPattern    = regexp.MustCompile(`^[0-9a-f]{40,64}$`)
	environmentPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

// config is written by lib/project-runtime.nix from a normalized descriptor.
type config struct {
	SchemaVersion        int                            `json:"schemaVersion"`
	Project              string                         `json:"project"`
	Realization          string                         `json:"realization"`
	EndpointProtocols    map[string]string              `json:"endpointProtocols"`
	ParameterDefinitions map[string]parameterDefinition `json:"parameterDefinitions"`
	Secrets              []string                       `json:"secrets"`
	Requirements         map[string]requirement         `json:"requirements"`
	Environment          environmentDefinition          `json:"environment"`
	// Release only.
	Actions            map[string]string            `json:"actions"`
	DefaultAction      string                       `json:"defaultAction"`
	Activation         string                       `json:"activation"`
	AuxiliaryEndpoints map[string]map[string]string `json:"auxiliaryEndpoints"`
}

type parameterDefinition struct {
	Type        string          `json:"type"`
	Description string          `json:"description"`
	Required    bool            `json:"required"`
	Default     json.RawMessage `json:"default"`
}

func (definition parameterDefinition) hasDefault() bool {
	return len(definition.Default) > 0
}

type requirement struct {
	Kind          string   `json:"kind"`
	Description   string   `json:"description"`
	Required      bool     `json:"required"`
	Realizations  []string `json:"realizations"`
	MajorVersions []int64  `json:"majorVersions"`
	DataDirectory string   `json:"dataDirectory"`
	Path          string   `json:"path"`
	Persistent    *bool    `json:"persistent"`
	Generate      *struct {
		Bytes int `json:"bytes"`
	} `json:"generate"`
}

func (value requirement) appliesTo(realization string) bool {
	for _, item := range value.Realizations {
		if item == realization {
			return true
		}
	}
	return false
}

func (value requirement) isPersistent() bool {
	return value.Persistent == nil || *value.Persistent
}

type environmentDefinition struct {
	Common  map[string]reference            `json:"common"`
	Actions map[string]map[string]reference `json:"actions"`
}

// reference is a literal string or one pointer into the runtime context.
type reference struct {
	Literal   *string
	Binding   string `json:"binding"`
	Endpoint  string `json:"endpoint"`
	Parameter string `json:"parameter"`
	Path      string `json:"path"`
	Instance  string `json:"instance"`
	Field     string `json:"field"`
	Append    string `json:"append"`
}

func (value *reference) UnmarshalJSON(data []byte) error {
	if bytes.HasPrefix(bytes.TrimSpace(data), []byte(`"`)) {
		var literal string
		if err := json.Unmarshal(data, &literal); err != nil {
			return err
		}
		value.Literal = &literal
		return nil
	}
	type fields reference
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode((*fields)(value))
}

func (value config) validate() {
	if value.SchemaVersion != 2 {
		fail(exitData, "runtime configuration /schemaVersion: unsupported version")
	}
	if value.Realization != "development" && value.Realization != "release" {
		fail(exitData, "runtime configuration /realization: must be development or release")
	}
	for _, mappings := range append([]map[string]reference{value.Environment.Common}, mapValues(value.Environment.Actions)...) {
		for variable := range mappings {
			if !environmentPattern.MatchString(variable) {
				fail(exitData, "runtime configuration: invalid environment variable %s", variable)
			}
		}
	}
}

func mapValues[V any](values map[string]V) []V {
	result := make([]V, 0, len(values))
	for _, name := range sortedKeys(values) {
		result = append(result, values[name])
	}
	return result
}
