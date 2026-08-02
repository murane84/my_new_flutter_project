import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy

app = Flask(__name__)

# Get the database password from environment variables
db_password = os.getenv('DB_PASSWORD')

# PostgreSQL database URI
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://postgres:{db_password}@localhost:5432/my_aluta_db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# Initialize the database
db = SQLAlchemy(app)

# Sample route
@app.route('/')
def home():
    return "Flask App Connected to PostgreSQL Successfully!"

if __name__ == '__main__':
    app.run(debug=True)
