// A2A Go SDK client driven by the CT suite.
//
// usage: client <base_url> <jsonrpc|rest> <scenario>
//
// Resolves the Agent Card at <base_url>/.well-known/agent-card.json,
// builds a client over the requested binding and runs one scenario
// against barrel_a2a_test_agent. Every step prints one JSON object per
// line on stdout; the Erlang side asserts on those. Exit code 0 means
// the scenario ran to the end.
//
// This mirrors test/interop/client.py and test/interop/js/client.mjs,
// including the step and field names, because the suite asserts on the
// same JSON for every language. Keep the three in step.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"
)

var bindings = map[string]a2a.TransportProtocol{
	"jsonrpc": a2a.TransportProtocolJSONRPC,
	"rest":    a2a.TransportProtocolHTTPJSON,
}

func emit(fields map[string]any) {
	line, err := json.Marshal(fields)
	if err != nil {
		fail(err)
	}
	fmt.Println(string(line))
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "%v\n", err)
	os.Exit(1)
}

func partsText(parts a2a.ContentParts) string {
	var b strings.Builder
	for _, p := range parts {
		if p == nil {
			continue
		}
		if text, ok := p.Content.(a2a.Text); ok {
			b.WriteString(string(text))
		}
	}
	return b.String()
}

func messageText(m *a2a.Message) string {
	if m == nil {
		return ""
	}
	return partsText(m.Parts)
}

func artifactText(t *a2a.Task) string {
	if t == nil {
		return ""
	}
	var b strings.Builder
	for _, a := range t.Artifacts {
		b.WriteString(partsText(a.Parts))
	}
	return b.String()
}

func userMessage(text string, taskID a2a.TaskID, contextID string) *a2a.Message {
	m := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart(text))
	m.TaskID = taskID
	m.ContextID = contextID
	return m
}

func makeClient(ctx context.Context, baseURL, binding string) *a2aclient.Client {
	card, err := agentcard.DefaultResolver.Resolve(ctx, baseURL)
	if err != nil {
		fail(fmt.Errorf("resolve card: %w", err))
	}
	client, err := a2aclient.NewFromCard(ctx, card, a2aclient.WithConfig(a2aclient.Config{
		PreferredTransports: []a2a.TransportProtocol{bindings[binding]},
	}))
	if err != nil {
		fail(fmt.Errorf("create client: %w", err))
	}
	return client
}

// One non-streaming send, reported in the same shape client.py uses:
// the SDK answers with a single task or message, so `kinds' has one
// entry. Only the `stream' scenario consumes the event stream.
func consume(ctx context.Context, c *a2aclient.Client, req *a2a.SendMessageRequest) ([]string, *a2a.Task, *a2a.Message) {
	result, err := c.SendMessage(ctx, req)
	if err != nil {
		fail(fmt.Errorf("send: %w", err))
	}
	switch v := result.(type) {
	case *a2a.Task:
		return []string{"task"}, v, nil
	case *a2a.Message:
		return []string{"message"}, nil, v
	default:
		fail(fmt.Errorf("unexpected send result %T", result))
		return nil, nil, nil
	}
}

func eventKind(ev a2a.Event) string {
	switch ev.(type) {
	case *a2a.Task:
		return "task"
	case *a2a.Message:
		return "message"
	case *a2a.TaskStatusUpdateEvent:
		return "status_update"
	case *a2a.TaskArtifactUpdateEvent:
		return "artifact_update"
	default:
		return "empty"
	}
}

func scenarioCard(ctx context.Context, baseURL, binding string) {
	card := makeClient(ctx, baseURL, binding).Card()
	interfaces := make([]map[string]any, 0, len(card.SupportedInterfaces))
	for _, i := range card.SupportedInterfaces {
		interfaces = append(interfaces, map[string]any{
			"binding": string(i.ProtocolBinding),
			"url":     i.URL,
			"version": string(i.ProtocolVersion),
		})
	}
	emit(map[string]any{
		"step":       "card",
		"name":       card.Name,
		"skills":     len(card.Skills),
		"streaming":  card.Capabilities.Streaming,
		"interfaces": interfaces,
	})
}

func scenarioSend(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	kinds, task, _ := consume(ctx, c, &a2a.SendMessageRequest{
		Message: userMessage("echo: interop", "", ""),
	})
	emit(map[string]any{
		"step": "send", "kinds": kinds, "state": task.Status.State.String(),
		"artifact": artifactText(task), "task_id": string(task.ID),
		"context_id": task.ContextID,
	})
}

func scenarioStream(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	var kinds []string
	var task *a2a.Task
	lastState := ""
	for ev, err := range c.SendStreamingMessage(ctx, &a2a.SendMessageRequest{
		Message: userMessage("stream", "", ""),
	}) {
		if err != nil {
			fail(fmt.Errorf("stream: %w", err))
		}
		kind := eventKind(ev)
		kinds = append(kinds, kind)
		entry := map[string]any{"step": "event", "kind": kind}
		switch v := ev.(type) {
		case *a2a.Task:
			task = v
			entry["state"] = v.Status.State.String()
		case *a2a.TaskStatusUpdateEvent:
			entry["state"] = v.Status.State.String()
			entry["final"] = v.Status.State.Terminal()
			lastState = v.Status.State.String()
		case *a2a.TaskArtifactUpdateEvent:
			entry["append"] = v.Append
			entry["last_chunk"] = v.LastChunk
			entry["text"] = partsText(v.Artifact.Parts)
		}
		emit(entry)
	}
	taskID := any(nil)
	if task != nil {
		taskID = string(task.ID)
	}
	emit(map[string]any{"step": "stream", "kinds": kinds, "state": lastState, "task_id": taskID})
}

func scenarioMultiturn(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	_, task, _ := consume(ctx, c, &a2a.SendMessageRequest{Message: userMessage("ask", "", "")})
	emit(map[string]any{
		"step": "ask", "state": task.Status.State.String(),
		"prompt": messageText(task.Status.Message), "task_id": string(task.ID),
		"context_id": task.ContextID,
	})
	_, done, _ := consume(ctx, c, &a2a.SendMessageRequest{
		Message: userMessage("second", task.ID, task.ContextID),
	})
	emit(map[string]any{
		"step": "multiturn", "state": done.Status.State.String(),
		"artifact": artifactText(done), "same_task": done.ID == task.ID,
		"history": len(done.History),
	})
}

func scenarioCancel(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	_, task, _ := consume(ctx, c, &a2a.SendMessageRequest{
		Message: userMessage("cancel-me", "", ""),
		Config:  &a2a.SendMessageConfig{ReturnImmediately: true},
	})
	emit(map[string]any{"step": "started", "state": task.Status.State.String(), "task_id": string(task.ID)})
	canceled, err := c.CancelTask(ctx, &a2a.CancelTaskRequest{ID: task.ID})
	if err != nil {
		fail(fmt.Errorf("cancel: %w", err))
	}
	emit(map[string]any{"step": "cancel", "state": canceled.Status.State.String(), "task_id": string(canceled.ID)})
	fetched, err := c.GetTask(ctx, &a2a.GetTaskRequest{ID: task.ID})
	if err != nil {
		fail(fmt.Errorf("get after cancel: %w", err))
	}
	emit(map[string]any{"step": "after_cancel", "state": fetched.Status.State.String()})
}

func scenarioDirect(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	kinds, _, msg := consume(ctx, c, &a2a.SendMessageRequest{Message: userMessage("direct", "", "")})
	emit(map[string]any{
		"step": "direct", "kinds": kinds, "text": messageText(msg),
		"role": string(msg.Role),
	})
}

func scenarioGet(ctx context.Context, baseURL, binding string) {
	c := makeClient(ctx, baseURL, binding)
	_, task, _ := consume(ctx, c, &a2a.SendMessageRequest{Message: userMessage("echo: x", "", "")})
	fetched, err := c.GetTask(ctx, &a2a.GetTaskRequest{ID: task.ID})
	if err != nil {
		fail(fmt.Errorf("get: %w", err))
	}
	emit(map[string]any{
		"step": "get", "state": fetched.Status.State.String(),
		"same_id": fetched.ID == task.ID, "artifact": artifactText(fetched),
	})
}

func main() {
	args := os.Args[1:]
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: client <base_url> <jsonrpc|rest> <scenario>")
		os.Exit(2)
	}
	baseURL, binding, scenario := args[0], args[1], args[2]
	if _, ok := bindings[binding]; !ok {
		fmt.Fprintln(os.Stderr, "usage: client <base_url> <jsonrpc|rest> <scenario>")
		os.Exit(2)
	}

	scenarios := map[string]func(context.Context, string, string){
		"card":      scenarioCard,
		"send":      scenarioSend,
		"stream":    scenarioStream,
		"multiturn": scenarioMultiturn,
		"cancel":    scenarioCancel,
		"direct":    scenarioDirect,
		"get":       scenarioGet,
	}
	run, ok := scenarios[scenario]
	if !ok {
		fmt.Fprintln(os.Stderr, "usage: client <base_url> <jsonrpc|rest> <scenario>")
		os.Exit(2)
	}
	run(context.Background(), baseURL, binding)
	emit(map[string]any{"step": "done"})
}
