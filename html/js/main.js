// Speakers the server knows about, keyed by owner server id (string).
// receivedAt is performance.now() at arrival; positions are extrapolated from it.
const emitters = new Map();

// Fixed pool of YouTube players. Each one is a full Chromium iframe decoding video, so the pool never grows past settings.maxActivePlayers.
// Slots are reused between speakers and destroyed after sitting idle, so a client with nobody playing nearby has no iframes at all.
const slots = [];

let settings = {
	maxActivePlayers: 3,
	driftTolerance: 3.0,
	idlePlayerLifetime: 60,
	debug: false,
};

let nextSlotId = 0;

const resourceName = GetParentResourceName();

const playerState = {
	unstarted: -1,
	ended: 0,
	playing: 1,
	paused: 2,
	buffering: 3,
	cued: 5,
};

const emitterState = {
	stopped: 0,
	playing: 1,
	paused: 2,
};

// Defined before iframe_api loads (see index.html), so the API can't become ready before anyone listens.
const youtubeReady = new Promise((resolve) => {
	window.onYouTubeIframeAPIReady = resolve;
});

// ========================
// Helpers
// ========================

function Post(name, data) {
	return fetch(`https://${resourceName}/${name}`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json; charset=UTF-8' },
		body: JSON.stringify(data ?? {}),
	});
}

// Sent to the client script, which prints it to the F8 console; this page's own console isn't visible in game.
function Log(message) {
	if (!settings.debug) {
		return;
	}
	console.log('[Frantic_Youtube] ' + message);
	Post('Log', { message: message }).catch(() => {});
}

function DescribeState(state) {
	return Object.keys(playerState).find((name) => playerState[name] === state) ?? String(state);
}

function ExpectedPosition(emitter) {
	let position = emitter.position;
	if (emitter.state === emitterState.playing) {
		position += (performance.now() - emitter.receivedAt) / 1000;
	}
	if (emitter.duration > 0) {
		position = Math.min(position, emitter.duration);
	}
	return Math.max(0, position);
}

// ========================
// Slots
// ========================

// The slot is registered synchronously so two assignments in a row can't both claim a free position in the pool.
// Each slot resolves its own ready promise; the old single global resolver lost every player but the last when two were created at once.
function CreateSlot() {
	const slot = {
		id: nextSlotId++,
		player: null,
		isReady: false,
		destroyed: false,
		pendingSync: false,
		emitterId: null,
		videoId: null,
		volume: 0,
		appliedVolume: null,
		errored: false,
		reportedReady: false,
		lastSeekAt: 0,
		releasedAt: performance.now(),
	};

	slot.ready = youtubeReady.then(() => new Promise((resolve) => {
		const element = document.createElement('div');
		element.id = 'YTPlayer-' + slot.id;
		document.getElementById('players').appendChild(element);

		slot.player = new YT.Player(element.id, {
			height: '0',
			width: '0',
			playerVars: {
				autoplay: 0,
				controls: 0,
				disablekb: 1,
				playsinline: 1,
			},
			events: {
				onReady: () => {
					Log(`Player ${slot.id} ready`);
					slot.isReady = true;
					resolve();
				},
				onStateChange: (event) => OnSlotStateChange(slot, event),
				onError: (event) => OnSlotError(slot, event),
			},
		});
	}));

	slots.push(slot);
	Log(`Creating player ${slot.id} (${slots.length}/${settings.maxActivePlayers} in pool)`);
	return slot;
}

function DestroySlot(slot) {
	Log(`Destroying idle player ${slot.id}`);
	slot.destroyed = true;
	const iframe = slot.player.getIframe?.();
	slot.player.destroy();
	iframe?.remove();
	document.getElementById('YTPlayer-' + slot.id)?.remove();
	slots.splice(slots.indexOf(slot), 1);
}

function AssignSlot(emitterId) {
	let slot = slots.find((candidate) => candidate.emitterId === null && !candidate.destroyed);
	if (!slot) {
		if (slots.length >= settings.maxActivePlayers) {
			Log(`No free player for speaker ${emitterId}; pool is full`);
			return null;
		}
		slot = CreateSlot();
	}

	Log(`Player ${slot.id} -> speaker ${emitterId}`);
	slot.emitterId = emitterId;
	return slot;
}

function ReleaseSlot(slot) {
	Log(`Player ${slot.id} released from speaker ${slot.emitterId}`);
	slot.emitterId = null;
	slot.releasedAt = performance.now();
	if (slot.isReady && slot.videoId !== null) {
		// stopVideo also stops buffering, so a released slot stops using bandwidth.
		slot.player.stopVideo();
	}
	slot.videoId = null;
}

function FindSlot(emitterId) {
	return slots.find((slot) => slot.emitterId === emitterId);
}

// Brings one slot's player in line with its speaker. Safe to call as often as needed: it only touches the player when something differs.
function SyncSlot(slot) {
	if (slot.destroyed || slot.emitterId === null) {
		return;
	}

	if (!slot.isReady) {
		if (!slot.pendingSync) {
			slot.pendingSync = true;
			slot.ready.then(() => {
				slot.pendingSync = false;
				SyncSlot(slot);
			});
		}
		return;
	}

	const player = slot.player;
	const emitter = emitters.get(slot.emitterId);
	if (!emitter || emitter.state === emitterState.stopped) {
		if (slot.videoId !== null) {
			player.stopVideo();
			slot.videoId = null;
		}
		return;
	}

	if (slot.appliedVolume !== slot.volume) {
		player.setVolume(slot.volume);
		slot.appliedVolume = slot.volume;
	}

	const expected = ExpectedPosition(emitter);

	if (slot.videoId !== emitter.videoId) {
		slot.videoId = emitter.videoId;
		slot.errored = false;
		slot.reportedReady = false;
		slot.lastSeekAt = performance.now();

		const request = { videoId: emitter.videoId, startSeconds: expected };
		Log(`Player ${slot.id} ${emitter.state === emitterState.playing ? 'loads' : 'cues'} ${emitter.videoId} at ${expected.toFixed(1)}s, volume ${slot.volume}`);
		if (emitter.state === emitterState.playing) {
			player.loadVideoById(request);
		} else {
			player.cueVideoById(request);
		}
		player.unMute();
		return;
	}

	if (slot.errored) {
		return;
	}

	const state = player.getPlayerState();

	// An ended player is left alone: the server ends the speaker within a second, and calling playVideo() here would restart it from 0.
	if (state === playerState.ended) {
		return;
	}

	if (emitter.state === emitterState.playing) {
		if (state !== playerState.playing && state !== playerState.buffering) {
			player.playVideo();
		}
	} else if (state === playerState.playing || state === playerState.buffering) {
		player.pauseVideo();
	}

	// Seeks are rate limited, since a seek during buffering otherwise retriggers itself every tick.
	const canCheckDrift = state === playerState.playing || state === playerState.paused;
	if (canCheckDrift && performance.now() - slot.lastSeekAt > 2000 && Math.abs(player.getCurrentTime() - expected) > settings.driftTolerance) {
		Log(`Player ${slot.id} drifted (${player.getCurrentTime().toFixed(1)}s, expected ${expected.toFixed(1)}s); seeking`);
		player.seekTo(expected, true);
		slot.lastSeekAt = performance.now();
	}
}

function SyncEmitter(emitterId) {
	const slot = FindSlot(emitterId);
	if (slot) {
		SyncSlot(slot);
	}
}

function OnSlotStateChange(slot, event) {
	Log(`Player ${slot.id} (speaker ${slot.emitterId}, ${slot.videoId}) is now ${DescribeState(event.data)}`);
	if (event.data === playerState.playing && !slot.reportedReady && slot.emitterId !== null) {
		slot.reportedReady = true;
		Post('VideoReady', { id: slot.emitterId, videoId: slot.videoId, duration: slot.player.getDuration() }).catch(() => {});
	}
}

function OnSlotError(slot, event) {
	Log(`Player ${slot.id} error ${event.data} on ${slot.videoId} (2 = bad id, 5 = HTML5 error, 100 = removed/private, 101/150 = embedding disabled)`);
	slot.errored = true;
	if (slot.emitterId !== null) {
		Post('VideoError', { id: slot.emitterId, videoId: slot.videoId, code: event.data }).catch(() => {});
	}
}

// ========================
// Messages
// ========================

function SetEmitter(id, emitter) {
	if (emitter) {
		emitter.receivedAt = performance.now();
		emitters.set(id, emitter);
	} else {
		emitters.delete(id);
	}
	SyncEmitter(id);
}

function SetEmitters(allEmitters) {
	emitters.clear();
	const now = performance.now();
	for (const [id, emitter] of Object.entries(allEmitters ?? {})) {
		emitter.receivedAt = now;
		emitters.set(id, emitter);
	}
	slots.forEach(SyncSlot);
}

// volumes holds exactly the speakers that should have a player, chosen by the client script, with their volume (0 - 100).
function SetActive(volumes) {
	volumes = volumes ?? {};

	for (const slot of slots) {
		if (slot.emitterId !== null && !(slot.emitterId in volumes)) {
			ReleaseSlot(slot);
		}
	}

	for (const [id, volume] of Object.entries(volumes)) {
		const slot = FindSlot(id) ?? AssignSlot(id);
		if (!slot) {
			continue;
		}
		slot.volume = volume;
		SyncSlot(slot);
	}
}

window.addEventListener('message', (event) => {
	const data = event.data;
	switch (data.action) {
		case 'Init':
			settings = {
				maxActivePlayers: data.maxActivePlayers,
				driftTolerance: data.driftTolerance,
				idlePlayerLifetime: data.idlePlayerLifetime,
				debug: data.debug === true,
			};
			Log(`Initialised: up to ${settings.maxActivePlayers} players, YouTube API ${window.YT?.loaded ? 'loaded' : 'still loading'}`);
			break;
		case 'SetEmitter':
			SetEmitter(data.id, data.emitter);
			break;
		case 'SetEmitters':
			SetEmitters(data.emitters);
			break;
		case 'SetActive':
			SetActive(data.volumes);
			break;
		default:
			break;
	}
});

// Drift correction and idle cleanup.
setInterval(() => {
	const now = performance.now();
	for (const slot of [...slots]) {
		if (slot.emitterId !== null) {
			SyncSlot(slot);
		} else if (slot.isReady && !slot.destroyed && now - slot.releasedAt > settings.idlePlayerLifetime * 1000) {
			DestroySlot(slot);
		}
	}
}, 1000);

// The client script may not have registered its callbacks yet when the page loads, so keep asking until it answers.
(async function AnnounceReady() {
	for (let attempt = 0; attempt < 60; attempt++) {
		try {
			const response = await Post('NuiReady', {});
			if (response.ok) {
				return;
			}
		} catch (error) {
			// Not registered yet
		}
		await new Promise((resolve) => setTimeout(resolve, 1000));
	}
})();
