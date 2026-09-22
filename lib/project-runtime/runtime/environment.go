package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func secretPath(value manifest, name string) string {
	credential, present := value.secrets[name]
	if !present {
		return ""
	}
	return filepath.Join(os.Getenv("PROJECT_SECRETS_DIR"), credential)
}

func bindingValue(value manifest, name string, field string) any {
	bound, present := value.bindings[name]
	if !present {
		return nil
	}
	if bound["kind"] == "secret" && (field == "value" || field == "file") {
		path := secretPath(value, bound["credential"].(string))
		if path == "" {
			return nil
		}
		if field == "file" {
			return path
		}
		data, err := os.ReadFile(path)
		if err != nil {
			fail(exitUnavailable, "could not read Project secret file: %v", err)
		}
		return strings.TrimRight(string(data), "\n")
	}
	fieldValue, present := bound[field]
	if !present {
		fail(exitUnavailable, "unknown Project binding field: %s.%s", name, field)
	}
	return fieldValue
}

func resolveReference(value manifest, item reference) any {
	switch {
	case item.Literal != nil:
		return *item.Literal
	case item.Binding != "":
		return bindingValue(value, item.Binding, item.Field)
	case item.Parameter != "":
		return value.parameters[item.Parameter]
	case item.Instance != "":
		return value.instanceID
	case item.Path != "":
		path := value.paths[item.Path]
		if path == "" {
			return nil
		}
		if item.Append != "" {
			path = filepath.Join(path, item.Append)
		}
		return path
	case item.Endpoint != "":
		selected, present := value.endpoints[item.Endpoint]
		if !present {
			return nil
		}
		switch item.Field {
		case "url":
			return selected.url
		case "protocol":
			return selected.protocol
		case "hostNames":
			return selected.hostNames
		case "listen.host":
			return selected.host
		case "listen.port":
			return selected.port
		}
		fail(exitUnavailable, "unknown endpoint field: %s.%s", item.Endpoint, item.Field)
	}
	fail(exitData, "invalid environment reference")
	return nil
}

// environmentValues resolves the common and action mappings. A nil value
// unsets an absent optional input instead of inheriting it from the caller.
func environmentValues(configuration config, value manifest, action string) map[string]*string {
	mappings := map[string]reference{}
	for name, item := range configuration.Environment.Common {
		mappings[name] = item
	}
	for name, item := range configuration.Environment.Actions[action] {
		mappings[name] = item
	}
	result := map[string]*string{}
	for variable, item := range mappings {
		resolved := resolveReference(value, item)
		if resolved == nil {
			result[variable] = nil
			continue
		}
		text, ok := resolved.(string)
		if !ok {
			encoded, err := json.Marshal(resolved)
			if err != nil {
				fail(exitData, "cannot encode environment variable %s", variable)
			}
			text = string(encoded)
		}
		result[variable] = &text
	}
	return result
}

func applyEnvironment(configuration config, value manifest, action string) {
	for name, resolved := range environmentValues(configuration, value, action) {
		var err error
		if resolved == nil {
			err = os.Unsetenv(name)
		} else {
			err = os.Setenv(name, *resolved)
		}
		if err != nil {
			fail(exitUnavailable, "could not set Project environment %s: %v", name, err)
		}
	}
}

func printEnvironment(configuration config, value manifest, action string) {
	values := environmentValues(configuration, value, action)
	for _, name := range sortedKeys(values) {
		if values[name] == nil {
			fmt.Printf("unset %s\n", name)
		} else {
			fmt.Printf("export %s=%s\n", name, shellQuote(*values[name]))
		}
	}
}
