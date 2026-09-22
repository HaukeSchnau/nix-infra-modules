package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// manifestFile is the host-written runtime manifest named by PROJECT_RUNTIME_FILE.
type manifestFile struct {
	SchemaVersion int                                   `json:"schemaVersion"`
	Project       string                                `json:"project"`
	Realization   string                                `json:"realization"`
	Revision      *string                               `json:"revision"`
	InstanceID    string                                `json:"instanceId"`
	Paths         map[string]string                     `json:"paths"`
	Endpoints     map[string]manifestEndpoint           `json:"endpoints"`
	Parameters    map[string]json.RawMessage            `json:"parameters"`
	Secrets       map[string]string                     `json:"secrets"`
	Bindings      map[string]map[string]json.RawMessage `json:"bindings"`
}

type manifestEndpoint struct {
	Protocol   string   `json:"protocol"`
	URL        string   `json:"url"`
	Visibility *string  `json:"visibility"`
	HostNames  []string `json:"hostNames"`
	Listen     struct {
		Host string `json:"host"`
		Port int64  `json:"port"`
	} `json:"listen"`
}

type endpoint struct {
	protocol  string
	url       string
	host      string
	port      int64
	hostNames []string
}

// manifest is a validated runtime manifest.
type manifest struct {
	instanceID string
	revision   string
	paths      map[string]string
	endpoints  map[string]endpoint
	parameters map[string]any
	secrets    map[string]string
	bindings   map[string]map[string]any
}

func loadManifest(configuration config) manifest {
	path := os.Getenv("PROJECT_RUNTIME_FILE")
	if path == "" {
		fail(exitUnavailable, "PROJECT_RUNTIME_FILE is required; use native devenv for local development")
	}
	var raw manifestFile
	loadFile(path, "runtime manifest", &raw)
	return validateManifest(raw, configuration)
}

func decodeValue(data json.RawMessage) any {
	var value any
	if err := decodeStrict(data, &value); err != nil {
		fail(exitData, "runtime manifest: invalid value: %v", err)
	}
	return value
}

func parameterMatches(value any, parameterType string) bool {
	switch parameterType {
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "integer":
		number, ok := value.(json.Number)
		if !ok || strings.ContainsAny(number.String(), ".eE") {
			return false
		}
		_, err := number.Int64()
		return err == nil
	case "number":
		number, ok := value.(json.Number)
		if !ok {
			return false
		}
		parsed, err := number.Float64()
		return err == nil && !math.IsInf(parsed, 0) && !math.IsNaN(parsed)
	case "string":
		_, ok := value.(string)
		return ok
	}
	return false
}

func validateManifest(raw manifestFile, configuration config) manifest {
	if raw.SchemaVersion != 3 {
		fail(exitData, "runtime manifest /schemaVersion: unsupported version")
	}
	if raw.Project != configuration.Project {
		fail(exitData, "runtime manifest /project: expected %s, got %s", configuration.Project, raw.Project)
	}
	if raw.Realization != configuration.Realization {
		fail(exitData, "runtime manifest /realization: expected %s, got %s", configuration.Realization, raw.Realization)
	}
	if raw.InstanceID == "" {
		fail(exitData, "runtime manifest /instanceId: must be a non-empty string")
	}
	revision := ""
	if raw.Revision != nil {
		revision = *raw.Revision
		if !revisionPattern.MatchString(revision) {
			fail(exitData, "runtime manifest /revision: must be a lowercase Git object ID")
		}
	}

	required := []string{"state", "runtime"}
	if configuration.Realization == "development" {
		required = append(required, "checkout", "cache")
	}
	for name := range raw.Paths {
		if name != "checkout" && name != "state" && name != "cache" && name != "runtime" {
			fail(exitData, "runtime manifest /paths: unknown field %s", name)
		}
	}
	for _, name := range required {
		if !filepath.IsAbs(raw.Paths[name]) {
			fail(exitData, "runtime manifest /paths/%s: must be an absolute path", name)
		}
	}

	endpoints := make(map[string]endpoint, len(raw.Endpoints))
	for _, name := range sortedKeys(raw.Endpoints) {
		value := raw.Endpoints[name]
		pointer := "runtime manifest /endpoints/" + name
		if !namePattern.MatchString(name) {
			fail(exitData, "%s: invalid Endpoint", pointer)
		}
		if value.Listen.Host == "" || value.Listen.Port < 1 || value.Listen.Port > 65535 {
			fail(exitData, "%s/listen: needs a host and a port between 1 and 65535", pointer)
		}
		expected, declared := configuration.EndpointProtocols[name]
		if !declared {
			fail(exitData, "runtime manifest /endpoints: undeclared Endpoint %s", name)
		}
		if value.Protocol != expected {
			fail(exitData, "%s/protocol: expected %s", pointer, expected)
		}
		switch value.Protocol {
		case "http":
			if value.URL == "" {
				fail(exitData, "%s/url: must be a non-empty string", pointer)
			}
			seen := map[string]bool{}
			for _, hostName := range value.HostNames {
				if hostName == "" || seen[hostName] {
					fail(exitData, "%s/hostNames: invalid list", pointer)
				}
				seen[hostName] = true
			}
			if value.Visibility != nil && *value.Visibility != "local" && *value.Visibility != "tailnet" && *value.Visibility != "public" {
				fail(exitData, "%s/visibility: invalid value", pointer)
			}
		case "tcp":
			if value.URL != "" || value.HostNames != nil || value.Visibility != nil {
				fail(exitData, "%s: TCP Endpoints cannot declare publication fields", pointer)
			}
		default:
			fail(exitData, "%s/protocol: must be http or tcp", pointer)
		}
		hostNames := value.HostNames
		if hostNames == nil {
			hostNames = []string{}
		}
		endpoints[name] = endpoint{
			protocol:  value.Protocol,
			url:       value.URL,
			host:      value.Listen.Host,
			port:      value.Listen.Port,
			hostNames: hostNames,
		}
	}
	missing := []string{}
	for name := range configuration.EndpointProtocols {
		if _, ok := endpoints[name]; !ok {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		fail(exitData, "runtime manifest /endpoints: missing %s", strings.Join(missing, ", "))
	}

	for name := range raw.Parameters {
		if _, ok := configuration.ParameterDefinitions[name]; !ok {
			fail(exitData, "runtime manifest /parameters: unknown name %s", name)
		}
	}
	parameters := map[string]any{}
	for _, name := range sortedKeys(configuration.ParameterDefinitions) {
		definition := configuration.ParameterDefinitions[name]
		data, present := raw.Parameters[name]
		if !present && definition.hasDefault() {
			data, present = definition.Default, true
		}
		var value any
		if present {
			value = decodeValue(data)
		}
		if value == nil {
			if definition.Required {
				fail(exitUnavailable, "Project parameter is required: %s", name)
			}
		} else if !parameterMatches(value, definition.Type) {
			fail(exitData, "runtime manifest /parameters/%s: expected %s", name, definition.Type)
		}
		parameters[name] = value
	}

	declaredSecrets := map[string]bool{}
	for _, name := range configuration.Secrets {
		declaredSecrets[name] = true
	}
	for _, name := range sortedKeys(raw.Secrets) {
		credential := raw.Secrets[name]
		if !declaredSecrets[name] {
			fail(exitData, "runtime manifest /secrets: undeclared name %s", name)
		}
		if !credentialPattern.MatchString(credential) || credential == "." || credential == ".." {
			fail(exitUnavailable, "runtime manifest /secrets/%s: unsafe credential filename", name)
		}
	}
	secrets := raw.Secrets
	if secrets == nil {
		secrets = map[string]string{}
	}

	return manifest{
		instanceID: raw.InstanceID,
		revision:   revision,
		paths:      raw.Paths,
		endpoints:  endpoints,
		parameters: parameters,
		secrets:    secrets,
		bindings:   validateBindings(raw.Bindings, configuration, secrets),
	}
}

// validateBindings checks host-supplied resources against the requirements of
// this realization. Bindings never allocate anything.
func validateBindings(raw map[string]map[string]json.RawMessage, configuration config, secrets map[string]string) map[string]map[string]any {
	selected := map[string]requirement{}
	for name, value := range configuration.Requirements {
		if value.appliesTo(configuration.Realization) {
			selected[name] = value
		}
	}
	for name := range raw {
		if _, ok := selected[name]; !ok {
			fail(exitData, "runtime manifest /bindings: undeclared resource %s", name)
		}
	}
	result := map[string]map[string]any{}
	for _, name := range sortedKeys(selected) {
		value, present := raw[name]
		if !present {
			if selected[name].Required {
				fail(exitData, "runtime manifest /bindings/%s is required", name)
			}
			continue
		}
		fields := map[string]any{}
		for field, data := range value {
			fields[field] = decodeValue(data)
		}
		if reason := bindingProblem(selected[name], fields, func(credential string) bool {
			_, ok := secrets[credential]
			return ok
		}); reason != "" {
			fail(exitData, "runtime manifest /bindings/%s: %s", name, reason)
		}
		result[name] = fields
	}
	return result
}

// bindingProblem describes why a binding cannot satisfy a requirement, or
// returns "" when it can. Release planning reports the same reasons.
func bindingProblem(value requirement, binding map[string]any, credentialBound func(string) bool) string {
	if binding["kind"] != value.Kind {
		return "requires kind " + value.Kind
	}
	allowed := map[string][]string{
		"postgresql": {"kind", "majorVersion", "host", "port", "database", "user", "url", "dataDirectory"},
		"directory":  {"kind", "path", "persistent"},
		"secret":     {"kind", "credential"},
	}[value.Kind]
	for field := range binding {
		known := false
		for _, name := range allowed {
			known = known || field == name
		}
		if !known {
			return "has unknown field " + field
		}
	}
	nonEmpty := func(field string) bool {
		text, ok := binding[field].(string)
		return ok && text != ""
	}
	absolute := func(field string) bool {
		text, ok := binding[field].(string)
		return ok && filepath.IsAbs(text)
	}
	integer := func(field string) (int64, bool) {
		number, ok := binding[field].(json.Number)
		if !ok {
			return 0, false
		}
		result, err := number.Int64()
		return result, err == nil
	}
	switch value.Kind {
	case "postgresql":
		major, ok := integer("majorVersion")
		accepted := false
		for _, version := range value.MajorVersions {
			accepted = accepted || (ok && major == version)
		}
		if !accepted {
			return "requires a supported PostgreSQL major version"
		}
		if port, ok := integer("port"); !ok || port < 1 || port > 65535 {
			return "port must be between 1 and 65535"
		}
		for _, field := range []string{"host", "database", "user", "url"} {
			if !nonEmpty(field) {
				return field + " must be a non-empty string"
			}
		}
		if _, present := binding["dataDirectory"]; present && !absolute("dataDirectory") {
			return "dataDirectory must be absolute"
		}
	case "directory":
		persistent, ok := binding["persistent"].(bool)
		if !absolute("path") {
			return "path must be absolute"
		}
		if !ok || persistent != value.isPersistent() {
			return "has incompatible persistence"
		}
	case "secret":
		credential, _ := binding["credential"].(string)
		if !credentialPattern.MatchString(credential) || credential == "." || credential == ".." || !credentialBound(credential) {
			return "requires a bound credential"
		}
	default:
		return "has unsupported kind " + value.Kind
	}
	return ""
}
