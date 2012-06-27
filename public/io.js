IO = (function () {
	var callbacks = {};
	var socket;

	function fire (name, args) {
		if (!callbacks[name] instanceof Array) {
			return;
		}

		callbacks[name].forEach(function (func) {
			func.call(args);
		});
	}

	function register (name, func) {
		if (!callbacks[name] instanceof Array) {
			callbacks[name] = [];
		}

		callbacks[name].push(func);
	}

	function start (host, port) {
		if (socket) {
			return;
		}

		var socket = new WebSocket("ws://" + ListensOn.websocket.host + ":" + ListensOn.websocket.port + "/websocket");

		socket.onmessage = function (event) {
			var response = JSON.parse(event.data);

			fire(response[0], response[1]);
		}

		socket.onclose = function () {
			fire("close");
		}

		socket.onopen = function () {
			fire("open");
		}
	}

	function send (type, args) {
		if (!socket) {
			return;
		}

		socket.send(JSON.stringify([type, args]));
	}

	return {
		start: start,
		send:  send,

		register: register,
	};
})();
