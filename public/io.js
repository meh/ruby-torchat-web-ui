IO = (function () {
	var callbacks = {};
	var socket;

	function fire (name, arguments) {
		if (!callbacks[name] instanceof Array) {
			return;
		}

		callbacks[name].forEach(function (func) {
			func.apply(null, arguments);
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

	function send (type) {
		if (!socket) {
			return;
		}

		var arguments = Array.prototype.slice.apply(arguments);
		    arguments.shift();

		socket.send(JSON.stringify([type, arguments]));
	}

	return {
		start: start,
		send:  send,

		register: register,
	};
})();
