/*******************************************************************************

    An interface to get information about the node on which a request is
    operating

    copyright:      Copyright (c) 2013-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.client.request.model.INodeInfo;

import swarm.Const : NodeItem;


public interface INodeInfo
{
    /***************************************************************************

        Returns:
            the nodeitem (address/port) of the node with which this request is
            communicating

    ***************************************************************************/

    public NodeItem nodeitem ( );
}

