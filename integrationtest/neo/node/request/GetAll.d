/*******************************************************************************

    Internal implementation of the node's GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.GetAll;

import ocean.transition;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;

/*******************************************************************************

    The request handler for the table of handlers. When called, runs in a fiber
    that can be controlled via `connection`.

    Params:
        shared_resources = an opaque object containing resources owned by the
            node which are required by the request
        connection  = performs connection socket I/O and manages the fiber
        cmdver      = the version number of the Consume command as specified by
                      the client
        msg_payload = the payload of the first message of this request

*******************************************************************************/

public void handle_v0 ( Object shared_resources, RequestOnConn connection,
    Command.Version cmdver, Const!(void)[] msg_payload )
{
    auto storage = cast(Storage)shared_resources;
    assert(storage);

    scope rq = new GetAllImpl_v0;
    rq.handle(storage, connection, msg_payload);
}

/*******************************************************************************

    Implementation of the v0 GetAll request protocol.

*******************************************************************************/

private scope class GetAllImpl_v0
{
    import integrationtest.neo.common.GetAll;
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;

    /// Set by the Writer when the iteration over the records has finished. Used
    /// by the Controller to ignore incoming messages from that point.
    private bool has_ended;

    /// Code that suspended writer fiber waits for when the request is
    /// suspended.
    static immutable ResumeSuspendedFiber = 1;

    /// Fiber which handles iterating and sending records to the client.
    private class Writer
    {
        import swarm.neo.util.DelayedSuspender;

        private MessageFiber fiber;
        private DelayedSuspender suspender;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
            this.suspender = DelayedSuspender(
                &this.outer.request_event_dispatcher, this.outer.conn,
                this.fiber, ResumeSuspendedFiber);
        }

        void fiberMethod ( )
        {
            // Iterate over storage, sending records to client.
            foreach ( key, value; this.outer.storage.map )
            {
                this.suspender.suspendIfRequested();

                this.outer.request_event_dispatcher.send(this.fiber,
                    ( RequestOnConn.EventDispatcher.Payload payload )
                    {
                        payload.addCopy(MessageType.Record);
                        payload.add(key);
                        payload.addArray(value);
                    }
                );
            }

            this.outer.has_ended = true;

            // Send the End message to the client.
            this.outer.request_event_dispatcher.send(this.fiber,
                ( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addCopy(MessageType.End);
                }
            );
            this.outer.conn.flush();

            this.outer.request_event_dispatcher.receive(this.fiber,
                Message(MessageType.Ack));

            // Kill the controller fiber.
            this.outer.request_event_dispatcher.abort(
                this.outer.controller.fiber);
        }
    }

    /// Fiber which handles control messages from the client.
    private class Controller
    {
        MessageFiber fiber;

        this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
        }

        void fiberMethod ( )
        {
            bool stop;
            do
            {
                // Receive message from client.
                auto message = this.outer.request_event_dispatcher.receive(this.fiber,
                    Message(MessageType.Suspend), Message(MessageType.Resume),
                    Message(MessageType.Stop));

                // If the request has ended, ignore incoming control messages.
                // We may receive a control message which the client sent before
                // it received or processed the End message we sent.
                if (this.outer.has_ended)
                    continue;

                // Send ACK. The protocol guarantees that the client will not
                // send any further messages until it has received the ACK.
                this.outer.request_event_dispatcher.send(this.fiber,
                    ( RequestOnConn.EventDispatcher.Payload payload )
                    {
                        payload.addCopy(MessageType.Ack);
                    }
                );
                this.outer.conn.flush();

                // Carry out the specified control message.
                with ( MessageType ) switch ( message.type )
                {
                    case Suspend:
                        this.outer.writer.suspender.requestSuspension();
                        break;
                    case Resume:
                        this.outer.writer.suspender.resumeIfSuspended();
                        break;
                    case Stop:
                        stop = true;
                        this.outer.request_event_dispatcher.abort(
                            this.outer.writer.fiber);
                        break;
                    default:
                        assert(false);
                }
            }
            while ( !stop );
        }
    }

    /// Storage instance to iterate over.
    private Storage storage;

    /// Connection event dispatcher.
    private RequestOnConn.EventDispatcher conn;

    /// Writer fiber.
    private Writer writer;

    /// Controller fiber.
    private Controller controller;

    /// Multi-fiber event dispatcher.
    private RequestEventDispatcher request_event_dispatcher;

    /***************************************************************************

        Request handler.

        Params:
            storage = storage engine instance to operate on
            connection = connection to client
            msg_payload = initial message read from client to begin the request
                (the request code and version are assumed to be extracted)

    ***************************************************************************/

    final public void handle ( Storage storage, RequestOnConn connection,
        Const!(void)[] msg_payload )
    {
        try
        {
            this.storage = storage;
            this.conn = connection.event_dispatcher;

            // Read request setup info from client.
            bool start_suspended;
            this.conn.message_parser.parseBody(msg_payload, start_suspended);

            // Now ready to start sending data from the storage and to handle
            // control messages from the client. Each of these jobs is handled by a
            // separate fiber.
            this.writer = new Writer;
            this.controller = new Controller;

            if ( start_suspended )
                this.writer.suspender.requestSuspension();

            this.controller.fiber.start();
            this.writer.fiber.start();
            this.request_event_dispatcher.eventLoop(this.conn);
        }
        catch (Exception e)
        {
            // Inform client about the error
            this.conn.send(( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addCopy(MessageType.Error);
                }
            );
        }
    }
}
