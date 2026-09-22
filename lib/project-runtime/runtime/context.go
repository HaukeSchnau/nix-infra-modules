package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// prepareContext creates the instance directories and selects the directory
// holding secret credential files.
func prepareContext(value manifest) {
	for _, name := range []string{"state", "runtime", "cache"} {
		if path, ok := value.paths[name]; ok {
			if err := os.MkdirAll(path, 0o700); err != nil {
				fail(exitUnavailable, "could not create Project path %s: %v", name, err)
			}
		}
	}
	directory := os.Getenv("PROJECT_SECRETS_DIR")
	if directory == "" {
		directory = filepath.Join(value.paths["runtime"], "secrets")
		if err := os.MkdirAll(directory, 0o700); err != nil {
			fail(exitUnavailable, "could not create PROJECT_SECRETS_DIR: %v", err)
		}
		if err := os.Setenv("PROJECT_SECRETS_DIR", directory); err != nil {
			fail(exitUnavailable, "could not set PROJECT_SECRETS_DIR: %v", err)
		}
	} else if info, err := os.Stat(directory); err != nil || !info.IsDir() {
		fail(exitUnavailable, "PROJECT_SECRETS_DIR does not exist: %s", directory)
	}
	if !filepath.IsAbs(directory) {
		fail(exitUnavailable, "PROJECT_SECRETS_DIR must be an absolute path")
	}
}

func executeAction(configuration config, action string, executable string, arguments []string) int {
	if configuration.Realization != "release" {
		fail(exitUsage, "only Release runtimes execute actions")
	}
	if executable == "" {
		fail(exitUsage, "undeclared Project action: %s", action)
	}
	value := loadManifest(configuration)
	prepareContext(value)
	applyEnvironment(configuration, value, action)
	argv := append([]string{executable}, arguments...)
	if err := syscall.Exec(executable, argv, os.Environ()); err != nil {
		fail(exitOSError, "could not execute action %s: %v", action, err)
	}
	return 0
}

// flag removes a boolean flag from arguments.
func flag(arguments []string, name string) ([]string, bool) {
	result := make([]string, 0, len(arguments))
	found := false
	for _, argument := range arguments {
		if argument == name {
			found = true
			continue
		}
		result = append(result, argument)
	}
	return result, found
}

// printValue prints scalars plainly and structured values as JSON.
func printValue(value any, jsonOutput bool) {
	switch value.(type) {
	case nil, bool, map[string]any, []any, []string:
		jsonOutput = true
	}
	if !jsonOutput {
		fmt.Println(value)
		return
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		fail(exitData, "could not encode Project context value: %v", err)
	}
	fmt.Println(string(encoded))
}

func usage(condition bool, text string) {
	if !condition {
		fail(exitUsage, "usage: project-context %s", text)
	}
}

func contextQuery(configuration config, arguments []string) int {
	usage(len(arguments) > 0, "<path|endpoint|auxiliary|parameter|secret-file|binding|environment|snapshot|revision|instance-id> ...")
	value := loadManifest(configuration)
	prepareContext(value)
	command, arguments := arguments[0], arguments[1:]
	arguments, jsonOutput := flag(arguments, "--json")

	switch command {
	case "path":
		usage(len(arguments) == 1, "path <name>")
		path, ok := value.paths[arguments[0]]
		if !ok {
			fail(exitUnavailable, "Project path is unavailable: %s", arguments[0])
		}
		printValue(path, false)
	case "endpoint":
		usage(len(arguments) == 2, "endpoint <name> <field> [--json]")
		printValue(endpointField(value, arguments[0], arguments[1]), jsonOutput)
	case "auxiliary":
		usage(len(arguments) == 3 && !jsonOutput, "auxiliary <name> <port> <field>")
		name, ok := configuration.AuxiliaryEndpoints[arguments[0]][arguments[1]]
		if !ok {
			fail(exitUnavailable, "Project auxiliary port is unavailable: %s.%s", arguments[0], arguments[1])
		}
		printValue(endpointField(value, name, arguments[2]), false)
	case "parameter":
		arguments, fallback := option(arguments, "--default")
		usage(len(arguments) == 1, "parameter <name> [--default <value>] [--json]")
		if _, ok := configuration.ParameterDefinitions[arguments[0]]; !ok {
			fail(exitUnavailable, "Project parameter is undeclared: %s", arguments[0])
		}
		parameter := value.parameters[arguments[0]]
		if parameter == nil && fallback != "" {
			var parsed any
			if decodeStrict([]byte(fallback), &parsed) == nil {
				parameter = parsed
			} else {
				parameter = fallback
			}
		}
		printValue(parameter, jsonOutput)
	case "secret-file":
		arguments, required := flag(arguments, "--required")
		usage(len(arguments) == 1, "secret-file <name> [--required]")
		path := secretPath(value, arguments[0])
		if path == "" {
			if required {
				fail(exitUnavailable, "Project Secret is unavailable: %s", arguments[0])
			}
			return 1
		}
		if required {
			if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
				fail(exitUnavailable, "Project Secret file is missing or empty: %s", arguments[0])
			}
		}
		printValue(path, false)
	case "binding":
		usage(len(arguments) == 2, "binding <name> <field> [--json]")
		bound := bindingValue(value, arguments[0], arguments[1])
		if bound == nil {
			return 1
		}
		printValue(bound, jsonOutput)
	case "environment":
		usage(len(arguments) <= 1, "environment [action]")
		action := ""
		if len(arguments) == 1 {
			action = arguments[0]
		}
		printEnvironment(configuration, value, action)
	case "snapshot":
		usage(len(arguments) == 0, "snapshot")
		printValue(snapshot(configuration, value), true)
	case "revision":
		usage(len(arguments) == 0, "revision")
		if value.revision == "" {
			return 1
		}
		printValue(value.revision, false)
	case "instance-id":
		usage(len(arguments) == 0, "instance-id")
		printValue(value.instanceID, false)
	default:
		fail(exitUsage, "unknown project-context command: %s", command)
	}
	return 0
}

func endpointField(value manifest, name string, field string) any {
	selected, ok := value.endpoints[name]
	if !ok {
		fail(exitUnavailable, "Project Endpoint is unavailable: %s", name)
	}
	switch field {
	case "protocol":
		return selected.protocol
	case "url":
		if selected.url == "" {
			fail(exitUnavailable, "Project Endpoint field is unavailable: %s.url", name)
		}
		return selected.url
	case "listen-host":
		return selected.host
	case "listen-port":
		return selected.port
	case "host-names":
		return selected.hostNames
	}
	fail(exitUsage, "unknown Project Endpoint field: %s", field)
	return nil
}

func snapshot(configuration config, value manifest) map[string]any {
	endpoints := map[string]any{}
	for name, item := range value.endpoints {
		fields := map[string]any{
			"protocol":  item.protocol,
			"listen":    map[string]any{"host": item.host, "port": item.port},
			"hostNames": item.hostNames,
		}
		if item.url != "" {
			fields["url"] = item.url
		}
		endpoints[name] = fields
	}
	secretFiles := map[string]any{}
	for name := range value.secrets {
		secretFiles[name] = secretPath(value, name)
	}
	result := map[string]any{
		"schemaVersion": 1,
		"project":       configuration.Project,
		"realization":   configuration.Realization,
		"instanceId":    value.instanceID,
		"paths":         value.paths,
		"endpoints":     endpoints,
		"parameters":    value.parameters,
		"bindings":      value.bindings,
		"secretFiles":   secretFiles,
	}
	if value.revision != "" {
		result["revision"] = value.revision
	}
	return result
}

// shellQuote quotes a value for POSIX shells.
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}
