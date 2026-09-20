// A2A JavaScript SDK client driven by the CT suite.
//
// usage: client.mjs <base_url> <jsonrpc|rest> <scenario>
//
// Resolves the Agent Card at <base_url>/.well-known/agent-card.json,
// builds a client over the requested binding and runs one scenario
// against barrel_a2a_test_agent. Every step prints one JSON object per
// line on stdout; the Erlang side asserts on those. Exit code 0 means
// the scenario ran to the end.
//
// This mirrors test/interop/client.py, including the step names and
// field names, because the suite asserts on the same JSON for every
// language. Keep the two in step.

import { Role, TaskState } from '@a2a-js/sdk';
import {
  ClientFactory,
  ClientFactoryOptions,
  JsonRpcTransportFactory,
  RestTransportFactory,
} from '@a2a-js/sdk/client';

const TRANSPORTS = {
  jsonrpc: { factory: () => new JsonRpcTransportFactory(), name: 'JSONRPC' },
  rest: { factory: () => new RestTransportFactory(), name: 'HTTP+JSON' },
};

const emit = (fields) => process.stdout.write(`${JSON.stringify(fields)}\n`);

const stateName = (state) => TaskState[state] ?? String(state);

const partsText = (parts) =>
  (parts ?? [])
    .filter((p) => p.content?.$case === 'text')
    .map((p) => p.content.value)
    .join('');

const messageText = (message) => partsText(message?.parts);

const artifactText = (task) =>
  (task?.artifacts ?? []).map((a) => partsText(a.parts)).join('');

const userMessage = (text, taskId, contextId) => ({
  role: Role.ROLE_USER,
  messageId: crypto.randomUUID(),
  parts: [{ content: { $case: 'text', value: text }, metadata: undefined, filename: '', mediaType: 'text/plain' }],
  taskId,
  contextId,
  extensions: [],
  metadata: {},
  referenceTaskIds: [],
});

async function makeClient(baseUrl, binding) {
  const { factory } = TRANSPORTS[binding];
  const options = ClientFactoryOptions.createFrom(ClientFactoryOptions.default, {
    transports: [factory()],
    preferredTransports: [TRANSPORTS[binding].name],
  });
  return new ClientFactory(options).createFromUrl(baseUrl);
}

// One non-streaming send, reported in the same shape client.py uses:
// the SDK answers with a single task or message, so `kinds' has one
// entry. Only the `stream' scenario consumes the event stream.
async function consume(client, request) {
  const response = await client.sendMessage(request);
  const payload = response?.payload ?? response;
  const $case = payload?.$case;
  if ($case === 'message') {
    return { kinds: ['message'], task: null, message: payload.value };
  }
  if ($case === 'task') {
    return { kinds: ['task'], task: payload.value, message: null };
  }
  // Some transports hand back the bare object rather than the oneof.
  if (payload?.status) {
    return { kinds: ['task'], task: payload, message: null };
  }
  return { kinds: ['message'], task: null, message: payload };
}

const FINAL = new Set([
  TaskState.TASK_STATE_COMPLETED,
  TaskState.TASK_STATE_FAILED,
  TaskState.TASK_STATE_CANCELED,
  TaskState.TASK_STATE_REJECTED,
]);

const scenarios = {
  async card(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const card = await client.getAgentCard();
    emit({
      step: 'card',
      name: card.name,
      skills: card.skills.length,
      streaming: card.capabilities.streaming,
      interfaces: card.supportedInterfaces.map((i) => ({
        binding: i.protocolBinding,
        url: i.url,
        version: i.protocolVersion,
      })),
    });
  },

  async send(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const { kinds, task } = await consume(client, { message: userMessage('echo: interop') });
    emit({
      step: 'send',
      kinds,
      state: stateName(task.status.state),
      artifact: artifactText(task),
      task_id: task.id,
      context_id: task.contextId,
    });
  },

  async stream(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const events = [];
    let task = null;
    for await (const event of client.sendMessageStream({ message: userMessage('stream') })) {
      const payload = event.payload;
      if (!payload) continue;
      const entry = {};
      if (payload.$case === 'task') {
        task = payload.value;
        entry.kind = 'task';
        entry.state = stateName(task.status.state);
      } else if (payload.$case === 'statusUpdate') {
        entry.kind = 'status_update';
        entry.state = stateName(payload.value.status.state);
        entry.final = FINAL.has(payload.value.status.state);
      } else if (payload.$case === 'artifactUpdate') {
        entry.kind = 'artifact_update';
        entry.append = payload.value.append ?? false;
        entry.last_chunk = payload.value.lastChunk ?? false;
        entry.text = partsText(payload.value.artifact.parts);
      } else {
        entry.kind = payload.$case;
      }
      events.push(entry);
      emit({ step: 'event', ...entry });
    }
    const last = events.filter((e) => e.kind === 'status_update').pop();
    emit({
      step: 'stream',
      kinds: events.map((e) => e.kind),
      state: last.state,
      task_id: task ? task.id : null,
    });
  },

  async multiturn(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const { task } = await consume(client, { message: userMessage('ask') });
    emit({
      step: 'ask',
      state: stateName(task.status.state),
      prompt: messageText(task.status.message),
      task_id: task.id,
      context_id: task.contextId,
    });
    const { task: done } = await consume(client, {
      message: userMessage('second', task.id, task.contextId),
    });
    emit({
      step: 'multiturn',
      state: stateName(done.status.state),
      artifact: artifactText(done),
      same_task: done.id === task.id,
      history: (done.history ?? []).length,
    });
  },

  async cancel(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const { task } = await consume(client, {
      message: userMessage('cancel-me'),
      configuration: { returnImmediately: true },
    });
    emit({ step: 'started', state: stateName(task.status.state), task_id: task.id });
    const canceled = await client.cancelTask({ id: task.id });
    emit({ step: 'cancel', state: stateName(canceled.status.state), task_id: canceled.id });
    const fetched = await client.getTask({ id: task.id });
    emit({ step: 'after_cancel', state: stateName(fetched.status.state) });
  },

  async direct(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const { kinds, message } = await consume(client, { message: userMessage('direct') });
    emit({ step: 'direct', kinds, text: messageText(message), role: Role[message.role] });
  },

  async get(baseUrl, binding) {
    const client = await makeClient(baseUrl, binding);
    const { task } = await consume(client, { message: userMessage('echo: x') });
    const fetched = await client.getTask({ id: task.id });
    emit({
      step: 'get',
      state: stateName(fetched.status.state),
      same_id: fetched.id === task.id,
      artifact: artifactText(fetched),
    });
  },
};

async function main([baseUrl, binding, scenario]) {
  if (!baseUrl || !TRANSPORTS[binding] || !scenarios[scenario]) {
    process.stderr.write('usage: client.mjs <base_url> <jsonrpc|rest> <scenario>\n');
    process.exit(2);
  }
  await scenarios[scenario](baseUrl, binding);
  emit({ step: 'done' });
}

main(process.argv.slice(2)).catch((err) => {
  process.stderr.write(`${err?.stack ?? err}\n`);
  process.exit(1);
});
