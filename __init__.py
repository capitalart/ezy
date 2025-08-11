from flask import Flask, render_template

def create_app():
    app = Flask(__name__, template_folder="templates", static_folder="static")

    @app.get("/health")
    def health():
        return "ok"

    @app.get("/")
    def index():
        return render_template("main.html")

    return app
