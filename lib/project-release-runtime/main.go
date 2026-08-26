package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
)

var (
	namePattern       = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	credentialPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	revisionPattern   = regexp.MustCompile(`^[0-9a-f]{40,64}$`)
)

type runtimeFailure struct {
	status  int
	message string
}

type endpoint struct {
	protocol  string
	url       string
	host      string
	port      int64
	hostNames []string
}

type manifest struct {
	revision   string
	paths      map[string]string
	endpoints  map[string]endpoint
	parameters map[string]any
	secrets    map[string]string
}

func fail(status int, format string, arguments ...any) {
	panic(runtimeFailure{status: status, message: fmt.Sprintf(format, arguments...)})
}

func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	return value, nil
}

func loadObject(path string, label string) map[string]any {
	data, err := os.ReadFile(path)
	if err != nil {
		fail(65, "%s %s: %v", label, path, err)
	}
	value, err := decodeJSON(data)
	if err != nil {
		fail(65, "%s %s: %v", label, path, err)
	}
	result, ok := value.(map[string]any)
	if !ok {
		fail(65, "%s %s: root must be an object", label, path)
	}
	return result
}

func object(value any, pointer string) map[string]any {
	result, ok := value.(map[string]any)
	if !ok {
		fail(65, "runtime manifest %s: must be an object", pointer)
	}
	return result
}

func stringValue(value any, pointer string) string {
	result, ok := value.(string)
	if !ok || result == "" {
		fail(65, "runtime manifest %s: must be a non-empty string", pointer)
	}
	return result
}

func integerValue(value any, pointer string) int64 {
	number, ok := value.(json.Number)
	if !ok || strings.ContainsAny(number.String(), ".eE") {
		fail(65, "runtime manifest %s: must be an integer", pointer)
	}
	result, err := number.Int64()
	if err != nil {
		fail(65, "runtime manifest %s: must be an integer", pointer)
	}
	return result
}

func keySet(values []string) map[string]struct{} {
	result := make(map[string]struct{}, len(values))
	for _, value := range values {
		result[value] = struct{}{}
	}
	return result
}

func sortedKeys(values map[string]any) []string {
	result := make([]string, 0, len(values))
	for name := range values {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

func unknownKeys(values map[string]any, allowed map[string]struct{}) []string {
	result := []string{}
	for name := range values {
		if _, ok := allowed[name]; !ok {
			result = append(result, name)
		}
	}
	sort.Strings(result)
	return result
}

func configString(config map[string]any, name string) string {
	value, ok := config[name].(string)
	if !ok || value == "" {
		fail(65, "runtime configuration /%s: must be a non-empty string", name)
	}
	return value
}

func configInteger(config map[string]any, name string, fallback int64) int64 {
	value, ok := config[name]
	if !ok {
		return fallback
	}
	number, ok := value.(json.Number)
	if !ok {
		fail(65, "runtime configuration /%s: must be an integer", name)
	}
	result, err := number.Int64()
	if err != nil {
		fail(65, "runtime configuration /%s: must be an integer", name)
	}
	return result
}

func configObject(config map[string]any, name string) map[string]any {
	value, ok := config[name]
	if !ok {
		return map[string]any{}
	}
	result, ok := value.(map[string]any)
	if !ok {
		fail(65, "runtime configuration /%s: must be an object", name)
	}
	return result
}

func configStrings(config map[string]any, name string) []string {
	value, ok := config[name]
	if !ok {
		return nil
	}
	items, ok := value.([]any)
	if !ok {
		fail(65, "runtime configuration /%s: must be an array", name)
	}
	result := make([]string, len(items))
	for index, item := range items {
		text, ok := item.(string)
		if !ok {
			fail(65, "runtime configuration /%s/%d: must be a string", name, index)
		}
		result[index] = text
	}
	return result
}

func validateParameter(value any, parameterType string, required bool, name string) {
	if value == nil && !required {
		return
	}
	valid := false
	switch parameterType {
	case "boolean":
		_, valid = value.(bool)
	case "integer":
		if number, ok := value.(json.Number); ok && !strings.ContainsAny(number.String(), ".eE") {
			_, err := number.Int64()
			valid = err == nil
		}
	case "number":
		if number, ok := value.(json.Number); ok {
			parsed, err := number.Float64()
			valid = err == nil && !math.IsInf(parsed, 0) && !math.IsNaN(parsed)
		}
	case "string":
		_, valid = value.(string)
	default:
		valid = false
	}
	if !valid {
		fail(65, "runtime manifest /parameters/%s: expected %s", name, parameterType)
	}
}

func validateManifest(raw map[string]any, config map[string]any) manifest {
	schemaVersion := integerValue(raw["schemaVersion"], "/schemaVersion")
	if schemaVersion != 1 && schemaVersion != 2 {
		fail(65, "runtime manifest /schemaVersion: unsupported version")
	}
	descriptorSchemaVersion := configInteger(config, "descriptorSchemaVersion", 1)
	if schemaVersion == 2 && descriptorSchemaVersion < 2 {
		fail(65, "runtime manifest /schemaVersion: version 2 requires a v2 or newer Project descriptor")
	}

	allowedRoot := keySet([]string{
		"schemaVersion", "project", "realization", "revision", "paths", "endpoints", "parameters", "secrets",
	})
	if schemaVersion == 1 {
		allowedRoot["settings"] = struct{}{}
	}
	if unknown := unknownKeys(raw, allowedRoot); len(unknown) > 0 {
		fail(65, "runtime manifest: unknown fields: %s", strings.Join(unknown, ", "))
	}
	project := configString(config, "project")
	if raw["project"] != project {
		fail(65, "runtime manifest /project: expected %s, got %v", project, raw["project"])
	}
	realization := configString(config, "realization")
	if raw["realization"] != realization {
		fail(65, "runtime manifest /realization: expected %s, got %v", realization, raw["realization"])
	}
	if realization != "release" {
		fail(65, "runtime configuration /realization: compiled Release runtime requires release")
	}
	revision := ""
	if rawRevision, present := raw["revision"]; present {
		var ok bool
		revision, ok = rawRevision.(string)
		if !ok || !revisionPattern.MatchString(revision) {
			fail(65, "runtime manifest /revision: must be a lowercase Git object ID")
		}
	}

	rawPaths := object(raw["paths"], "/paths")
	if unknown := unknownKeys(rawPaths, keySet([]string{"checkout", "state", "cache", "runtime"})); len(unknown) > 0 {
		fail(65, "runtime manifest /paths: unknown fields: %s", strings.Join(unknown, ", "))
	}
	paths := map[string]string{}
	for _, name := range []string{"state", "runtime"} {
		value := stringValue(rawPaths[name], "/paths/"+name)
		if !filepath.IsAbs(value) {
			fail(65, "runtime manifest /paths/%s: must be an absolute path", name)
		}
		paths[name] = value
	}
	for _, name := range []string{"checkout", "cache"} {
		if value, ok := rawPaths[name].(string); ok {
			paths[name] = value
		}
	}

	rawEndpoints := object(raw["endpoints"], "/endpoints")
	endpoints := make(map[string]endpoint, len(rawEndpoints))
	for _, name := range sortedKeys(rawEndpoints) {
		if !namePattern.MatchString(name) {
			fail(65, "runtime manifest /endpoints/%s: invalid Endpoint", name)
		}
		rawEndpoint := object(rawEndpoints[name], "/endpoints/"+name)
		allowedEndpoint := keySet([]string{"url", "listen", "hostNames", "visibility"})
		if schemaVersion == 2 {
			allowedEndpoint["protocol"] = struct{}{}
		}
		if unknown := unknownKeys(rawEndpoint, allowedEndpoint); len(unknown) > 0 {
			fail(65, "runtime manifest /endpoints/%s: unknown fields: %s", name, strings.Join(unknown, ", "))
		}
		listen := object(rawEndpoint["listen"], "/endpoints/"+name+"/listen")
		if unknown := unknownKeys(listen, keySet([]string{"host", "port"})); len(unknown) > 0 {
			fail(65, "runtime manifest /endpoints/%s/listen: unknown fields: %s", name, strings.Join(unknown, ", "))
		}
		host := stringValue(listen["host"], "/endpoints/"+name+"/listen/host")
		port := integerValue(listen["port"], "/endpoints/"+name+"/listen/port")
		if port < 1 || port > 65535 {
			fail(65, "runtime manifest /endpoints/%s/listen/port: invalid port", name)
		}
		protocol := "http"
		if schemaVersion == 2 {
			protocol = stringValue(rawEndpoint["protocol"], "/endpoints/"+name+"/protocol")
		}
		if protocol != "http" && protocol != "tcp" {
			fail(65, "runtime manifest /endpoints/%s/protocol: must be http or tcp", name)
		}
		value := endpoint{protocol: protocol, host: host, port: port, hostNames: []string{}}
		if protocol == "http" {
			value.url = stringValue(rawEndpoint["url"], "/endpoints/"+name+"/url")
			if rawHostNames, ok := rawEndpoint["hostNames"]; ok {
				items, ok := rawHostNames.([]any)
				if !ok {
					fail(65, "runtime manifest /endpoints/%s/hostNames: invalid list", name)
				}
				seen := map[string]struct{}{}
				for _, item := range items {
					hostName, ok := item.(string)
					if !ok || hostName == "" {
						fail(65, "runtime manifest /endpoints/%s/hostNames: invalid list", name)
					}
					if _, duplicate := seen[hostName]; duplicate {
						fail(65, "runtime manifest /endpoints/%s/hostNames: invalid list", name)
					}
					seen[hostName] = struct{}{}
					value.hostNames = append(value.hostNames, hostName)
				}
			}
			if visibility, ok := rawEndpoint["visibility"]; ok && visibility != nil {
				text, ok := visibility.(string)
				if !ok || (text != "local" && text != "tailnet" && text != "public") {
					fail(65, "runtime manifest /endpoints/%s/visibility: invalid value", name)
				}
			}
		} else {
			publicationFields := []string{}
			for _, field := range []string{"url", "hostNames", "visibility"} {
				if _, ok := rawEndpoint[field]; ok {
					publicationFields = append(publicationFields, field)
				}
			}
			if len(publicationFields) > 0 {
				fail(65, "runtime manifest /endpoints/%s: TCP Endpoints cannot declare publication fields: %s", name, strings.Join(publicationFields, ", "))
			}
		}
		endpoints[name] = value
	}

	if expectedNames, ok := config["endpoints"]; ok {
		items, ok := expectedNames.([]any)
		if !ok {
			fail(65, "runtime configuration /endpoints: must be an array")
		}
		expected := map[string]struct{}{}
		for _, item := range items {
			name, ok := item.(string)
			if !ok {
				fail(65, "runtime configuration /endpoints: must contain strings")
			}
			expected[name] = struct{}{}
		}
		missing := []string{}
		extra := []string{}
		for name := range expected {
			if _, ok := endpoints[name]; !ok {
				missing = append(missing, name)
			}
		}
		for name := range endpoints {
			if _, ok := expected[name]; !ok {
				extra = append(extra, name)
			}
		}
		sort.Strings(missing)
		sort.Strings(extra)
		if len(missing) > 0 || len(extra) > 0 {
			missingText := "-"
			extraText := "-"
			if len(missing) > 0 {
				missingText = strings.Join(missing, ", ")
			}
			if len(extra) > 0 {
				extraText = strings.Join(extra, ", ")
			}
			fail(65, "runtime manifest /endpoints: does not match descriptor (missing: %s; extra: %s)", missingText, extraText)
		}
		expectedProtocols := configObject(config, "endpointProtocols")
		mismatched := []string{}
		for name, endpoint := range endpoints {
			expectedProtocol := "http"
			if configured, ok := expectedProtocols[name].(string); ok {
				expectedProtocol = configured
			}
			if endpoint.protocol != expectedProtocol {
				mismatched = append(mismatched, name)
			}
		}
		sort.Strings(mismatched)
		if len(mismatched) > 0 {
			fail(65, "runtime manifest /endpoints: protocols do not match descriptor: %s", strings.Join(mismatched, ", "))
		}
	}

	if _, hasParameters := raw["parameters"]; hasParameters {
		if _, hasSettings := raw["settings"]; hasSettings {
			fail(65, "runtime manifest: set parameters, not both parameters and legacy settings")
		}
	}
	rawParameters, ok := raw["parameters"]
	if !ok {
		rawParameters = raw["settings"]
	}
	if rawParameters == nil {
		rawParameters = map[string]any{}
	}
	parameters := object(rawParameters, "/parameters")
	definitions := configObject(config, "parameterDefinitions")
	unknownParameters := []string{}
	for name := range parameters {
		if _, ok := definitions[name]; !ok {
			unknownParameters = append(unknownParameters, name)
		}
	}
	sort.Strings(unknownParameters)
	if len(unknownParameters) > 0 {
		fail(65, "runtime manifest /parameters: unknown names: %s", strings.Join(unknownParameters, ", "))
	}
	normalizedParameters := map[string]any{}
	for _, name := range sortedKeys(definitions) {
		definition, ok := definitions[name].(map[string]any)
		if !ok {
			fail(65, "runtime configuration /parameterDefinitions/%s: must be an object", name)
		}
		required, _ := definition["required"].(bool)
		value, present := parameters[name]
		if !present {
			value, present = definition["default"]
		}
		if !present {
			if required {
				fail(66, "Project parameter is required: %s", name)
			}
			value = nil
		}
		parameterType, _ := definition["type"].(string)
		validateParameter(value, parameterType, required, name)
		normalizedParameters[name] = value
	}

	rawSecrets := raw["secrets"]
	if rawSecrets == nil {
		rawSecrets = map[string]any{}
	}
	secretValues := object(rawSecrets, "/secrets")
	declaredSecrets := keySet(configStrings(config, "secrets"))
	secrets := map[string]string{}
	undeclaredSecrets := []string{}
	for _, name := range sortedKeys(secretValues) {
		if !credentialPattern.MatchString(name) {
			fail(65, "runtime manifest /secrets/%s: invalid semantic name", name)
		}
		credential, ok := secretValues[name].(string)
		if !ok || !credentialPattern.MatchString(credential) {
			fail(66, "runtime manifest /secrets/%s: unsafe credential filename", name)
		}
		if _, ok := declaredSecrets[name]; !ok {
			undeclaredSecrets = append(undeclaredSecrets, name)
		}
		secrets[name] = credential
	}
	if len(undeclaredSecrets) > 0 {
		fail(65, "runtime manifest /secrets: undeclared names: %s", strings.Join(undeclaredSecrets, ", "))
	}

	return manifest{
		revision:   revision,
		paths:      paths,
		endpoints:  endpoints,
		parameters: normalizedParameters,
		secrets:    secrets,
	}
}

func loadManifest(config map[string]any) manifest {
	path := os.Getenv("PROJECT_RUNTIME_FILE")
	if path == "" {
		fail(66, "PROJECT_RUNTIME_FILE is required for a Release")
	}
	return validateManifest(loadObject(path, "runtime manifest"), config)
}

func prepareContext(value manifest) {
	for _, name := range []string{"state", "runtime", "cache"} {
		path, ok := value.paths[name]
		if !ok {
			continue
		}
		if err := os.MkdirAll(path, 0o700); err != nil {
			fail(66, "could not create Project path %s: %v", name, err)
		}
	}
	secretsDirectory := os.Getenv("PROJECT_SECRETS_DIR")
	if secretsDirectory == "" {
		secretsDirectory = filepath.Join(value.paths["runtime"], "secrets")
		if err := os.MkdirAll(secretsDirectory, 0o700); err != nil {
			fail(66, "could not create PROJECT_SECRETS_DIR: %v", err)
		}
		if err := os.Setenv("PROJECT_SECRETS_DIR", secretsDirectory); err != nil {
			fail(66, "could not set PROJECT_SECRETS_DIR: %v", err)
		}
	} else {
		info, err := os.Stat(secretsDirectory)
		if err != nil || !info.IsDir() {
			fail(66, "PROJECT_SECRETS_DIR does not exist: %s", secretsDirectory)
		}
	}
	if !filepath.IsAbs(secretsDirectory) {
		fail(66, "PROJECT_SECRETS_DIR must be an absolute path")
	}
}

func actionExecutable(config map[string]any, action string, activation bool) string {
	if activation {
		executable, ok := config["activation"].(string)
		if !ok || executable == "" {
			fail(64, "this Release has no activation action")
		}
		return executable
	}
	actions := configObject(config, "actions")
	executable, ok := actions[action].(string)
	if !ok || executable == "" {
		fail(64, "undeclared Project action: %s", action)
	}
	return executable
}

func executeAction(config map[string]any, action string, arguments []string, activation bool) int {
	executable := actionExecutable(config, action, activation)
	value := loadManifest(config)
	prepareContext(value)
	argv := append([]string{executable}, arguments...)
	if err := syscall.Exec(executable, argv, os.Environ()); err != nil {
		fail(69, "could not execute action %s: %v", action, err)
	}
	return 0
}

func removeFlag(arguments []string, name string) ([]string, bool) {
	result := make([]string, 0, len(arguments))
	found := false
	for _, argument := range arguments {
		if argument == name {
			if found {
				fail(64, "duplicate option: %s", name)
			}
			found = true
			continue
		}
		result = append(result, argument)
	}
	return result, found
}

func parameterOptions(arguments []string) ([]string, *string, bool) {
	result := []string{}
	var defaultValue *string
	jsonOutput := false
	for index := 0; index < len(arguments); index++ {
		switch arguments[index] {
		case "--json":
			if jsonOutput {
				fail(64, "duplicate option: --json")
			}
			jsonOutput = true
		case "--default":
			if defaultValue != nil || index+1 >= len(arguments) {
				fail(64, "usage: project-context parameter <name> [--default <value>] [--json]")
			}
			index++
			value := arguments[index]
			defaultValue = &value
		default:
			result = append(result, arguments[index])
		}
	}
	return result, defaultValue, jsonOutput
}

func parseDefault(value string) any {
	parsed, err := decodeJSON([]byte(value))
	if err != nil {
		return value
	}
	return parsed
}

func printValue(value any, jsonOutput bool) {
	_, isBool := value.(bool)
	_, isObject := value.(map[string]any)
	_, isAnyList := value.([]any)
	_, isStringList := value.([]string)
	if jsonOutput || value == nil || isBool || isObject || isAnyList || isStringList {
		encoded, err := json.Marshal(value)
		if err != nil {
			fail(65, "could not encode Project context value: %v", err)
		}
		fmt.Println(string(encoded))
		return
	}
	fmt.Println(value)
}

func contextSnapshot(config map[string]any, value manifest) map[string]any {
	endpoints := make(map[string]any, len(value.endpoints))
	for name, endpoint := range value.endpoints {
		fields := map[string]any{
			"protocol": endpoint.protocol,
			"listen": map[string]any{
				"host": endpoint.host,
				"port": endpoint.port,
			},
			"hostNames": endpoint.hostNames,
		}
		if endpoint.url != "" {
			fields["url"] = endpoint.url
		}
		endpoints[name] = fields
	}

	secretFiles := make(map[string]any, len(value.secrets))
	for name, credential := range value.secrets {
		secretFiles[name] = filepath.Join(os.Getenv("PROJECT_SECRETS_DIR"), credential)
	}

	result := map[string]any{
		"schemaVersion": 1,
		"project":       config["project"],
		"realization":   config["realization"],
		"paths":         value.paths,
		"endpoints":     endpoints,
		"parameters":    value.parameters,
		"secretFiles":   secretFiles,
	}
	if value.revision != "" {
		result["revision"] = value.revision
	}
	return result
}

func contextQuery(config map[string]any, arguments []string) int {
	if len(arguments) == 0 {
		fail(64, "usage: project-context <command>")
	}
	value := loadManifest(config)
	prepareContext(value)

	switch arguments[0] {
	case "path":
		if len(arguments) != 2 {
			fail(64, "usage: project-context path <name>")
		}
		path, ok := value.paths[arguments[1]]
		if !ok {
			fail(66, "Project path is unavailable: %s", arguments[1])
		}
		printValue(path, false)
	case "endpoint":
		rest, jsonOutput := removeFlag(arguments[1:], "--json")
		if len(rest) != 2 {
			fail(64, "usage: project-context endpoint <name> <field> [--json]")
		}
		queryEndpoint(value, rest[0], rest[1], jsonOutput)
	case "auxiliary":
		rest, jsonOutput := removeFlag(arguments[1:], "--json")
		if jsonOutput || len(rest) != 3 {
			fail(64, "usage: project-context auxiliary <name> <port> <field>")
		}
		auxiliaries := configObject(config, "auxiliaryEndpoints")
		ports, ok := auxiliaries[rest[0]].(map[string]any)
		if !ok {
			fail(66, "Project auxiliary port is unavailable: %s.%s", rest[0], rest[1])
		}
		endpointName, ok := ports[rest[1]].(string)
		if !ok {
			fail(66, "Project auxiliary port is unavailable: %s.%s", rest[0], rest[1])
		}
		queryEndpoint(value, endpointName, rest[2], false)
	case "parameter":
		rest, defaultValue, jsonOutput := parameterOptions(arguments[1:])
		if len(rest) != 1 {
			fail(64, "usage: project-context parameter <name> [--default <value>] [--json]")
		}
		definitions := configObject(config, "parameterDefinitions")
		if _, ok := definitions[rest[0]]; !ok {
			fail(66, "Project parameter is undeclared: %s", rest[0])
		}
		parameter := value.parameters[rest[0]]
		if parameter == nil && defaultValue != nil {
			parameter = parseDefault(*defaultValue)
		}
		printValue(parameter, jsonOutput)
	case "secret-file":
		rest, required := removeFlag(arguments[1:], "--required")
		if len(rest) != 1 {
			fail(64, "usage: project-context secret-file <name> [--required]")
		}
		credential, ok := value.secrets[rest[0]]
		if !ok {
			if required {
				fail(66, "Project Secret is unavailable: %s", rest[0])
			}
			return 1
		}
		path := filepath.Join(os.Getenv("PROJECT_SECRETS_DIR"), credential)
		if required {
			info, err := os.Stat(path)
			if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
				fail(66, "Project Secret file is missing or empty: %s", rest[0])
			}
		}
		printValue(path, false)
	case "snapshot":
		if len(arguments) != 1 {
			fail(64, "usage: project-context snapshot")
		}
		printValue(contextSnapshot(config, value), true)
	case "revision":
		if len(arguments) != 1 {
			fail(64, "usage: project-context revision")
		}
		if value.revision == "" {
			return 1
		}
		printValue(value.revision, false)
	default:
		fail(64, "unknown project-context command: %s", arguments[0])
	}
	return 0
}

func queryEndpoint(value manifest, name string, field string, jsonOutput bool) {
	endpoint, ok := value.endpoints[name]
	if !ok {
		fail(66, "Project Endpoint is unavailable: %s", name)
	}
	switch field {
	case "protocol":
		printValue(endpoint.protocol, jsonOutput)
	case "url":
		if endpoint.url == "" {
			fail(66, "Project Endpoint field is unavailable: %s.%s", name, field)
		}
		printValue(endpoint.url, jsonOutput)
	case "listen-host":
		printValue(endpoint.host, jsonOutput)
	case "listen-port":
		printValue(endpoint.port, jsonOutput)
	case "host-names":
		printValue(endpoint.hostNames, jsonOutput)
	default:
		fail(64, "unknown Project Endpoint field: %s", field)
	}
}

func run(arguments []string) int {
	if len(arguments) < 2 || arguments[0] != "--config" {
		fail(64, "usage: project-runtime --config <path> [action]")
	}
	config := loadObject(arguments[1], "runtime configuration")
	remaining := arguments[2:]
	if len(remaining) > 0 && remaining[0] == "context" {
		return contextQuery(config, remaining[1:])
	}
	if len(remaining) == 1 && remaining[0] == "--activate" {
		return executeAction(config, "activation", nil, true)
	}
	action := ""
	if len(remaining) == 0 {
		action, _ = config["defaultAction"].(string)
	} else if len(remaining) >= 1 {
		action = remaining[0]
	} else {
		fail(64, "usage: project runtime <action> [arguments...]")
	}
	if action == "" {
		fail(64, "this Project Runtime has no default action")
	}
	actionArguments := []string{}
	if len(remaining) > 1 {
		actionArguments = remaining[1:]
	}
	return executeAction(config, action, actionArguments, false)
}

func executeMain() (status int) {
	defer func() {
		if recovered := recover(); recovered != nil {
			failure, ok := recovered.(runtimeFailure)
			if !ok {
				panic(recovered)
			}
			fmt.Fprintf(os.Stderr, "project-runtime: %s\n", failure.message)
			status = failure.status
		}
	}()
	return run(os.Args[1:])
}

func main() {
	os.Exit(executeMain())
}
