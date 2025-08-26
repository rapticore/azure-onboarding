import os
import logging
import azure.functions as func
from processor import handle_signin_log

app = func.FunctionApp()

EVENT_HUB_NAME = os.environ["EVENT_HUB_NAME"]
EVENT_HUB_CONSUMER_GROUP = os.environ["EVENT_HUB_CONSUMER_GROUP"]

@app.event_hub_message_trigger(
    arg_name="azeventhub",
    event_hub_name=EVENT_HUB_NAME,
    connection="EventHubConnectionString",
    consumer_group=EVENT_HUB_CONSUMER_GROUP
)
def eventhub_trigger1(azeventhub: func.EventHubEvent):
    logging.info(
        "Python EventHub trigger processed an event: %s",
        azeventhub.get_body().decode("utf-8")
    )
    event_body = azeventhub.get_body().decode("utf-8")
    handle_signin_log(event_body)

