import logging
import azure.functions as func
from shared.processor import handle_signin_log


def main(event: func.EventHubEvent):
    event_body = event.get_body().decode("utf-8")
    logging.info("Received message from interactive-signin-logs")
    handle_signin_log(event_body)
