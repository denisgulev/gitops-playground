# Use an official Python base image
FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Create working directory
WORKDIR /app

# Copy app code into container
COPY app.py .

# Install Flask
RUN pip install flask

# Expose the port Flask will run on
EXPOSE 8000

# Run the application
CMD ["python", "app.py"]