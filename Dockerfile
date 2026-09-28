# Backend (Flask). Намеренно "как у разработчиков": старый базовый образ,
# root-пользователь, нет HEALTHCHECK, apt без очистки, нет .dockerignore.
FROM python:3.11-slim-bookworm

WORKDIR /app

# iputils-ping нужен для маршрута /ping (command injection)
RUN apt-get update && apt-get install -y curl iputils-ping

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

ENV FLASK_ENV=development
EXPOSE 5000

CMD ["python", "app.py"]
