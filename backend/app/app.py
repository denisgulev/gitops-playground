from flask import Flask, jsonify, request, redirect

app = Flask(__name__)

STATIC_SITE_URL = "https://static-website.denisgulev.com"  # Replace with your static site URL

@app.route("/api/hello")
def hello():
    return jsonify(message="Hello from Flask!")

@app.errorhandler(404)
def page_not_found(e):
    return redirect(f"{STATIC_SITE_URL}/error.html", code=302)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)