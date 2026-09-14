package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var environmentPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Bindings are supplied by the host. Validation and environment resolution never allocate resources.
func validateBindings(raw map[string]any, config map[string]any, secrets map[string]string) map[string]map[string]any {
	requirements := configObject(config, "requirements")
	selected := map[string]any{}
	for name, item := range requirements {
		requirement := object(item, "/requirements/"+name)
		realizations := configStrings(requirement, "realizations")
		if len(realizations) == 0 {
			selected[name] = requirement
		} else {
			for _, realization := range realizations {
				if realization == config["realization"] {
					selected[name] = requirement
				}
			}
		}
	}
	if unknown := unknownKeys(raw, keySet(sortedKeys(selected))); len(unknown) > 0 {
		fail(65, "runtime manifest /bindings: undeclared resources: %s", strings.Join(unknown, ", "))
	}
	result := map[string]map[string]any{}
	for _, name := range sortedKeys(selected) {
		requirement := object(selected[name], "/requirements/"+name)
		prefix := "/bindings/" + name
		bound, present := raw[name]
		if !present {
			if requirement["required"] != false {
				fail(65, "runtime manifest %s is required", prefix)
			}
			continue
		}
		value := object(bound, prefix)
		kind := requirement["kind"]
		if value["kind"] != kind {
			fail(65, "runtime manifest %s must satisfy kind %v", prefix, kind)
		}
		allowed := []string{"kind"}
		switch kind {
		case "postgresql":
			allowed = append(allowed, "majorVersion", "host", "port", "database", "user", "url", "dataDirectory")
			major := integerValue(value["majorVersion"], prefix+"/majorVersion")
			versions, present := requirement["majorVersions"].([]any)
			if !present {
				versions = []any{requirement["majorVersion"]}
			}
			accepted := false
			for _, version := range versions {
				if major == integerValue(version, "/requirements/"+name+"/majorVersions") {
					accepted = true
				}
			}
			if !accepted {
				fail(65, "runtime manifest %s requires PostgreSQL %v", prefix, versions)
			}
			port := integerValue(value["port"], prefix+"/port")
			if port < 1 || port > 65535 {
				fail(65, "runtime manifest %s/port must be between 1 and 65535", prefix)
			}
			for _, field := range []string{"host", "database", "user", "url"} {
				stringValue(value[field], prefix+"/"+field)
			}
			if path, present := value["dataDirectory"]; present && !filepath.IsAbs(stringValue(path, prefix+"/dataDirectory")) {
				fail(65, "runtime manifest %s/dataDirectory must be absolute", prefix)
			}
		case "directory":
			allowed = append(allowed, "path", "persistent")
			if !filepath.IsAbs(stringValue(value["path"], prefix+"/path")) {
				fail(65, "runtime manifest %s/path must be absolute", prefix)
			}
			persistent, ok := value["persistent"].(bool)
			expected := requirement["persistent"] != false
			if !ok || persistent != expected {
				fail(65, "runtime manifest %s/persistent does not satisfy the requirement", prefix)
			}
		case "secret":
			allowed = append(allowed, "credential")
			credential := stringValue(value["credential"], prefix+"/credential")
			if _, ok := secrets[credential]; !ok {
				fail(65, "runtime manifest %s/credential must reference a bound secret", prefix)
			}
		default:
			fail(65, "runtime configuration requires unsupported resource kind %v", kind)
		}
		if unknown := unknownKeys(value, keySet(allowed)); len(unknown) > 0 {
			fail(65, "runtime manifest %s has unknown fields: %s", prefix, strings.Join(unknown, ", "))
		}
		result[name] = value
	}
	return result
}

func secretPath(value manifest, name string) string {
	credential, present := value.secrets[name]
	if !present {
		return ""
	}
	return filepath.Join(os.Getenv("PROJECT_SECRETS_DIR"), credential)
}

func secretContents(path string) any {
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail(66, "could not read Project secret file: %v", err)
	}
	return strings.TrimRight(string(data), "\n")
}

func bindingValue(value manifest, name string, field string) any {
	bound, present := value.bindings[name]
	if !present {
		return nil
	}
	if bound["kind"] == "secret" && (field == "value" || field == "file") {
		path := secretPath(value, bound["credential"].(string))
		if field == "file" {
			return path
		}
		return secretContents(path)
	}
	fieldValue, present := bound[field]
	if !present {
		fail(66, "unknown Project binding field: %s.%s", name, field)
	}
	return fieldValue
}

// A nil result explicitly unsets an absent optional input instead of inheriting host values.
func environmentValues(config map[string]any, value manifest, action string) map[string]any {
	definition := configObject(config, "environment")
	mappings := map[string]any{}
	for name, reference := range configObject(definition, "common") {
		mappings[name] = reference
	}
	for name, reference := range configObject(configObject(definition, "actions"), action) {
		mappings[name] = reference
	}
	result := map[string]any{}
	for variable, reference := range mappings {
		if !environmentPattern.MatchString(variable) {
			fail(65, "invalid environment variable: %s", variable)
		}
		var resolved any
		if literal, ok := reference.(string); ok {
			resolved = literal
		} else {
			fields := object(reference, "/environment/"+variable)
			switch {
			case fields["binding"] != nil:
				resolved = bindingValue(value, stringValue(fields["binding"], "binding"), stringValue(fields["field"], "field"))
			case fields["secret"] != nil:
				resolved = secretContents(secretPath(value, stringValue(fields["secret"], "secret")))
			case fields["parameter"] != nil:
				resolved = value.parameters[stringValue(fields["parameter"], "parameter")]
			case fields["instance"] != nil:
				if value.instanceID != "" {
					resolved = value.instanceID
				}
			case fields["path"] != nil:
				path := value.paths[stringValue(fields["path"], "path")]
				if path != "" {
					if appendPath, ok := fields["append"].(string); ok {
						path = filepath.Join(path, appendPath)
					}
					resolved = path
				}
			case fields["endpoint"] != nil:
				name := stringValue(fields["endpoint"], "endpoint")
				if endpoint, present := value.endpoints[name]; present {
					switch fields["field"] {
					case "url":
						resolved = endpoint.url
					case "protocol":
						resolved = endpoint.protocol
					case "hostNames":
						resolved = endpoint.hostNames
					case "listen.host":
						resolved = endpoint.host
					case "listen.port":
						resolved = endpoint.port
					default:
						fail(66, "unknown endpoint field: %s.%v", name, fields["field"])
					}
				}
			default:
				fail(65, "invalid environment reference: %s", variable)
			}
		}
		if resolved != nil {
			if _, ok := resolved.(string); !ok {
				encoded, err := json.Marshal(resolved)
				if err != nil {
					fail(65, "cannot encode environment variable %s", variable)
				}
				resolved = string(encoded)
			}
		}
		result[variable] = resolved
	}
	return result
}

func applyEnvironment(config map[string]any, value manifest, action string) {
	for name, value := range environmentValues(config, value, action) {
		var err error
		if value == nil {
			err = os.Unsetenv(name)
		} else {
			err = os.Setenv(name, value.(string))
		}
		if err != nil {
			fail(66, "could not set Project environment %s: %v", name, err)
		}
	}
}

func printEnvironment(config map[string]any, value manifest, action string) {
	values := environmentValues(config, value, action)
	for _, name := range sortedKeys(values) {
		if values[name] == nil {
			fmt.Printf("unset %s\n", name)
		} else {
			quoted := "'" + strings.ReplaceAll(values[name].(string), "'", "'\"'\"'") + "'"
			fmt.Printf("export %s=%s\n", name, quoted)
		}
	}
}
