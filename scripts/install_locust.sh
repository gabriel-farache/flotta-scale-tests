#!/bin/bash
pip install locust wheel

git clone https://github.com/gabriel-farache/locust-plugins
cd locust-plugins/
make build
pip install dist/*
cd ..
