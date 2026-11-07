const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const bridgePath = path.join(__dirname, "..", "OpenRGBBridge.js");
const qmlPath = path.join(__dirname, "..", "OpenRGBBridge.qml");
const rawSource = fs.readFileSync(bridgePath, "utf8");
let source = rawSource;
const qmlSource = fs.readFileSync(qmlPath, "utf8");
source = source
	.replace(/^import\s+tcp\s+from\s+"@SignalRGB\/tcp";\s*/m, "")
	.replace(/\bexport function\b/g, "function");
source += "\nglobalThis.__bridgeTest = { DiscoveryService, OpenRGBClient, Initialize, Render };\n";

const settings = new Map();
const entries = [];
const controllers = new Map();
const announced = [];
const announcedControllers = [];
const suppressed = [];
const added = [];
const removed = [];
const sockets = [];

function findEntry(id) {
	return entries.find((entry) => entry.id === id);
}

const service = {
	controllers: entries,
	getSetting(group, key) {
		return settings.get(group + ":" + key);
	},
	saveSetting(group, key, value) {
		settings.set(group + ":" + key, value);
	},
	getController(id) {
		return controllers.get(id);
	},
	addController(controller) {
		added.push(controller.id);
		controllers.set(controller.id, controller);
		if (!findEntry(controller.id)) {
			entries.push({ id: controller.id, obj: controller });
		}
	},
	updateController(controller) {
		controllers.set(controller.id, controller);
		const entry = findEntry(controller.id);
		if (entry) {
			entry.obj = controller;
		}
	},
	removeController(controller) {
		const id = typeof controller === "string" ? controller : controller.id;
		removed.push(id);
		const index = entries.findIndex((entry) => entry.id === id);
		if (index >= 0) {
			entries.splice(index, 1);
		}
		controllers.delete(id);
	},
	announceController(controller) {
		announced.push(controller.id);
		announcedControllers.push(controller);
		controllers.set(controller.id, controller);
		if (!findEntry(controller.id)) {
			entries.push({ id: controller.id, obj: controller });
		}
	},
	suppressController(controller) {
		suppressed.push(controller.id);
		const index = entries.findIndex((entry) => entry.id === controller.id);
		if (index >= 0) {
			entries.splice(index, 1);
		}
	},
	log() {}
};

const context = {
	console,
	Date,
	JSON,
	Math,
	Map,
	Set,
	Uint8Array,
	ArrayBuffer,
	TextDecoder,
	service,
	tcp: {
		createSocket() {
			const socket = {
				handlers: {},
				sent: [],
				on(eventName, callback) {
					this.handlers[eventName] = callback;
				},
				connect(host, port) {
					this.host = host;
					this.port = port;
				},
				send(data) {
					this.sent.push(data);
				},
				close() {
					this.closed = true;
					if (this.handlers.close) {
						this.handlers.close();
					}
				}
			};
			sockets.push(socket);
			return socket;
		}
	},
	device: {
		log() {},
		setName(name) {
			this.name = name;
		},
		setImageFromUrl(image) {
			this.image = image;
		},
		setSize(size) {
			this.size = size;
		},
		setControllableLeds(names, positions) {
			this.ledNames = names;
			this.ledPositions = positions;
		}
	}
};
vm.createContext(context);
vm.runInContext(source, context, { filename: bridgePath });

// ---- OpenRGB packet helpers -------------------------------------------------
const u16 = (v) => [v & 0xff, (v >> 8) & 0xff];
const u32 = (v) => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff];
const str = (s) => { const b = [...Buffer.from(s + "\0")]; return u16(b.length).concat(b); };
const packet = (cmd, payload, dev) => [0x4f, 0x52, 0x47, 0x42].concat(u32(dev || 0), u32(cmd), u32(payload.length), payload);

function feGpuControllerData() {
	let body = [];
	body = body.concat(u32(2)); // device type GPU
	body = body.concat(str("NVIDIA GeForce RTX 3080 FE"), str("NVIDIA"), str("NVIDIA Illumination RGB GPU Device"), str(""), str(""), str(""));
	body = body.concat(u16(1), u32(0)); // 1 mode, active 0
	body = body.concat(str("Direct"), u32(0), u32(0x20), u32(0), u32(0), u32(0), u32(100), u32(0), u32(0), u32(0), u32(100), u32(0), u32(1), u16(0));
	body = body.concat(u16(2)); // 2 zones, one LED each
	for (const name of ["Logo", "Front Strip"]) {
		body = body.concat(str(name), u32(0), u32(1), u32(1), u32(1), u16(0), u16(0), u32(0));
	}
	body = body.concat(u16(2), str("Logo"), u32(0), str("Front Strip"), u32(1)); // LEDs
	body = body.concat(u16(2), [0, 0, 0, 0], [0, 0, 0, 0]); // colors
	body = body.concat(u16(0), u32(0)); // v5 alt names + flags
	return u32(body.length + 4).concat(body);
}

function runScan(discovery) {
	discovery.refresh("127.0.0.1", 6742);
	const socket = sockets[sockets.length - 1];
	socket.handlers.connection();
	socket.handlers.message(packet(40, u32(6)));          // server speaks protocol 6
	socket.handlers.message(packet(0, u32(1)));           // one controller
	socket.handlers.message(packet(1, feGpuControllerData(), 0));
	discovery.Update();                                    // no setTimeout in SignalRGB: sync runs on tick
}

const catalogue = (d) => JSON.parse(JSON.parse(d.getUiState(1)).devicesJson);

// ---- Scenario: user's state - an earlier empty scan saved an empty selection ----
settings.set("General:SelectedDevices", "[]");
const discovery = new context.__bridgeTest.DiscoveryService();
discovery.needsScan = false;
runScan(discovery);

const gpuId = catalogue(discovery)[0].deviceId;
assert.equal(catalogue(discovery).length, 1, "scan must list the FE GPU");
assert.equal(catalogue(discovery)[0].bridgeDeleted, false, "a stale empty selection must not hide a newly found device");
assert.ok(announced.includes(gpuId), "the FE GPU must be announced to SignalRGB");
assert.equal(catalogue(discovery)[0].ledCount, 2, "FE GPU exposes 2 LEDs");

// ---- Explicit delete must survive a rescan ----
discovery.removeDevice(gpuId);
discovery.Update();
runScan(discovery);
assert.equal(catalogue(discovery)[0].bridgeDeleted, true, "a device the user deleted must stay deleted after rescan");

// ---- Restore brings it back and survives a rescan ----
const announcedBefore = announced.length;
discovery.restoreDevice(gpuId);
discovery.Update();
runScan(discovery);
assert.equal(catalogue(discovery)[0].bridgeDeleted, false, "a restored device must stay active after rescan");
assert.ok(announced.length > announcedBefore, "restoring must announce the device again");

// ---- Delete All then a brand-new install-time startup keeps it deleted ----
discovery.removeAllDevices();
discovery.Update();
const fresh = new context.__bridgeTest.DiscoveryService();
fresh.needsScan = false;
runScan(fresh);
assert.equal(catalogue(fresh)[0].bridgeDeleted, true, "Delete All must persist across restarts");

// ---- Device -> local helper over HTTP (devices have no sockets on 2.5.86) ----
discovery.restoreAllDevices();
discovery.Update();
runScan(discovery);
const gpuController = announcedControllers[announcedControllers.length - 1];
Object.assign(context.device, {
	createSubdevice() {}, setSubdeviceName() {}, setSubdeviceSize() {}, setSubdeviceLeds() {},
	SetIsSubdeviceController() {}, pause() {},
	subdeviceColor(id) { return id.endsWith("Logo") ? [255, 0, 0] : [0, 0, 255]; },
	color() { return [0, 255, 0]; }
});
const requests = [];
let respond = 200;
context.XMLHttpRequest = function () {
	const xhr = this;
	xhr.readyState = 0;
	xhr.open = function (method, url) { xhr.method = method; xhr.url = url; };
	xhr.send = function () {
		requests.push(xhr.url);
		xhr.readyState = 4;
		xhr.status = respond;
		xhr.onreadystatechange();
	};
};
let fakeNow = Date.now();
context.Date = { now: () => fakeNow };
const step = (ms) => { fakeNow += ms; };
context.controller = gpuController;
Object.assign(context, { LightingMode: "Canvas", forcedColor: "#009bde", shutdownColor: "#009bde" });
context.device.log = (m) => { if (String(m).includes("OpenRGB Bridge:")) console.log("  device:", String(m)); };
context.__bridgeTest.Initialize();
context.__bridgeTest.Render();
assert.equal(requests.length, 1, "a changed frame must be sent to the helper");
assert.equal(requests[0], "http://localhost:6748/frame?h=127.0.0.1&p=6742&i=0&c=ff00000000ff",
	"the request must carry OpenRGB host, port, controller index and both zone colours");

step(40);
context.__bridgeTest.Render();
assert.equal(requests.length, 1, "an unchanged frame must not be resent");

// helper down: one log, backoff, newest colours resent after recovery
context.device.subdeviceColor = (id) => (id.endsWith("Logo") ? [0, 255, 0] : [0, 0, 255]);
respond = 0;
step(40);
context.__bridgeTest.Render();
assert.equal(requests.length, 2, "the new frame is attempted once");
step(40);
context.__bridgeTest.Render();
assert.equal(requests.length, 2, "no retry before the backoff expires");
respond = 200;
step(5000);
context.__bridgeTest.Render();
assert.equal(requests.length, 3, "the pending frame is retried after the backoff");
assert.match(requests[2], /c=00ff000000ff$/, "the retry carries the newest colours");

// rate cap: a burst of changing frames within one 33 ms window sends at most one request
const burstStart = requests.length;
for (let i = 0; i < 10; i++) {
	context.device.subdeviceColor = (id) => [i * 20, 0, id.endsWith("Logo") ? 1 : 2];
	step(3);
	context.__bridgeTest.Render();
}
assert.ok(requests.length - burstStart <= 1, "changing frames are capped at ~30 per second");
step(40);
context.__bridgeTest.Render();
assert.match(requests[requests.length - 1], /c=b4000100+b40002$|c=b40001b40002$/, "after the window the newest colours go out");
context.Date = Date;

console.log("Stale-selection validation passed.");
