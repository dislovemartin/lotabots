FROM ubuntu:22.04
LABEL Name=lotabots Version=0.0.1

# Install required packages
RUN apt-get update && apt-get install -y \
    fortune-mod \
    cowsay \
    && rm -rf /var/lib/apt/lists/*

# Add cowsay to PATH
ENV PATH="/usr/games:${PATH}"

# Create a script to run fortune-cowsay periodically
RUN echo '#!/bin/bash\nwhile true; do\n  fortune -a | cowsay\n  sleep 300\ndone' > /run-fortune.sh \
    && chmod +x /run-fortune.sh

# Set the command
CMD ["/run-fortune.sh"]
