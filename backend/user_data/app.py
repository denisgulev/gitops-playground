from flask import Flask, jsonify, request, redirect
import watchtower, logging

app = Flask(__name__)
LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.DEBUG)
LOGGER.addHandler(logging.StreamHandler())
LOGGER.addHandler(watchtower.CloudWatchLogHandler(log_group='application_template'))

@app.route('/api/hello')
def hello():
    LOGGER.info("Calling /api/hello")
    return jsonify(message="Hello from Flask behind Nginx!")

@app.errorhandler(404)
def page_not_found(e):
    LOGGER.warning(f"404 error: {request.path} not found.")
    return redirect("${static_origin}/error.html", code=302)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)