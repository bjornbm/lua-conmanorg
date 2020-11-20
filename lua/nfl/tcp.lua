-- ***************************************************************
--
-- Copyright 2018 by Sean Conner.  All Rights Reserved.
--
-- This library is free software; you can redistribute it and/or modify it
-- under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation; either version 3 of the License, or (at your
-- option) any later version.
--
-- This library is distributed in the hope that it will be useful, but
-- WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
-- License for more details.
--
-- You should have received a copy of the GNU Lesser General Public License
-- along with this library; if not, see <http://www.gnu.org/licenses/>.
--
-- Comments, questions and criticisms can be sent to: sean@conman.org
--
-- ********************************************************************
-- luacheck: globals listens listena listen connecta connect
-- luacheck: ignore 611

local syslog    = require "org.conman.syslog"
local errno     = require "org.conman.errno"
local net       = require "org.conman.net"
local mkios     = require "org.conman.net.ios"
local nfl       = require "org.conman.nfl"
local coroutine = require "coroutine"

local _VERSION  = _VERSION
local tostring  = tostring

if _VERSION == "Lua 5.1" then
  module(...)
else
  _ENV = {} -- luacheck: ignore
end

-- **********************************************************************
-- usage:       ios,handler = create_handler(conn,remote)
-- desc:        Create the event handler for handing network packets
-- input:       conn (userdata/socket) connected socket
--              remote (userdata/address) remote connection
-- return:      ios (table) I/O object (similar to what io.open() returns)
--              handler (function) event handler
-- **********************************************************************

local function create_handler(conn,remote)
  local writebuf = ""
  local ios      = mkios()
  ios.__remote   = remote
  
  ios._refill = function()
    return coroutine.yield()
  end
  
  ios._drain = function(_,data)
    writebuf = data
    nfl.SOCKETS:update(conn,'w')
    return coroutine.yield()
  end
  
  ios.close = function()
    -- ---------------------------------------------------------------------
    -- It might be a bug *somewhere*, but on Linux, this is required to get
    -- Unix domain sockets to work with the NFL driver.  There's a race
    -- condition where writting data then calling close() may cause the
    -- other side to receive no data.  This does NOT appoear to happen with
    -- TCP sockets, but this doesn't hurt the TCP side in any case.
    -- ---------------------------------------------------------------------
    
    while conn.sendqueue and conn.sendqueue > 0 do
      nfl.SOCKETS:update(conn,'w')
      coroutine.yield()
    end
    
    nfl.SOCKETS:remove(conn)
    local err = conn:close()
    return err == 0,errno[err],err
  end
  
  return ios,function(event)
    if event.hangup then
      nfl.SOCKETS:remove(conn)
      ios._eof = true
      nfl.schedule(ios.__co,false,errno.ECONNREFUSED)
      return
    end
    
    if event.read then
      local _,packet,err = conn:recv()
      if packet then
        if #packet == 0 then
          nfl.SOCKETS:remove(conn)
          ios._eof = true
        end
        nfl.schedule(ios.__co,packet)
        if ios._eof then return end
      else
        if err ~= errno.EAGAIN then
          syslog('error',"socket:recv() = %s",errno[err])
          nfl.SOCKETS:remove(conn)
          ios._eof = true
          nfl.schedule(ios.__co,false,err)
          return
        end
      end
    end
    
    if event.write then
      if #writebuf > 0 then
        local bytes,err = conn:send(nil,writebuf)
        if err == 0 then
          writebuf = writebuf:sub(bytes + 1,-1)
        else
          syslog('error',"socket:send() = %s",errno[err])
          nfl.SOCKETS:remove(conn)
          ios._eof = true
          nfl.schedule(ios.__co,false,err)
          return
        end
      end
      
      if #writebuf == 0 then
        nfl.SOCKETS:update(conn,'r')
        nfl.schedule(ios.__co,true)
      end
    end
  end
end

-- **********************************************************************
-- Usage:       sock,errmsg = listens(sock,mainf)
-- Desc:        Initialize a listening TCP socket
-- Input:       sock (userdata/socket) bound socket
--              mainf (function) main handler for service
-- Return:      sock (userdata) socket used for listening, false on error
--              errmsg (string) error message
-- **********************************************************************

function listens(sock,mainf)
  nfl.SOCKETS:insert(sock,'r',function()
    local conn,remote,err = sock:accept()
    
    if not conn then
      syslog('error',"sock:accept() = %s",errno[err])
      return
    end
    
    conn.nonblock = true
    local ios,packet_handler = create_handler(conn,remote)
    ios.__co = nfl.spawn(mainf,ios)
    nfl.SOCKETS:insert(conn,'r',packet_handler)
  end)
  
  return sock
end

-- **********************************************************************
-- Usage:       sock,errmsg = listena(addr,mainf)
-- Desc:        Initalize a listening TCP socket
-- Input:       addr (userdata/address) IP address
--              mainf (function) main handler for service
-- Return:      sock (userdata) socket used for listening, false on error
--              errmsg (string) error message
-- **********************************************************************

function listena(addr,mainf)
  local sock,err = net.socket(addr.family,'tcp')
  
  if not sock then
    return false,errno[err]
  end
  
  sock.reuseaddr = true
  sock.nonblock  = true
  sock:bind(addr)
  sock:listen()
  return listens(sock,mainf)
end

-- **********************************************************************
-- Usage:       listen(host,port,mainf)
-- Desc:        Initalize a listening TCP socket
-- Input:       host (string) address to bind to
--              port (string integer) port
--              mainf (function) main handler for service
-- **********************************************************************

function listen(host,port,mainf)
  return listena(net.address2(host,'any','tcp',port)[1],mainf)
end

-- **********************************************************************
-- Usage:       ios = tcp.connecta(addr[,to])
-- Desc:        Connect to a remote address
-- Input:       addr (userdata/address) IP address
--              to (number/optinal) timout the operation after to seconds
-- Return:      ios (table) Input/Output object (nil on error)
-- **********************************************************************

function connecta(addr,to)
  if not addr then return nil end
  
  local sock,err = net.socket(addr.family,'tcp')
  
  if not sock then
    syslog('error',"socket(TCP) = %s",errno[err])
    return
  end
  
  sock.nonblock            = true
  local ios,packet_handler = create_handler(sock,addr)
  ios.__co                 = coroutine.running()
  
  -- ------------------------------------------------------------
  -- In POSIXland, a non-blocking socket doing a connect become available
  -- when it's ready for writing.  So we install a 'write' trigger, then
  -- call connect() and yield.  When we return, it's connected (unless we're
  -- optionally timing out the operation).
  -- ------------------------------------------------------------
  
  nfl.SOCKETS:insert(sock,'w',packet_handler)
  if to then nfl.timeout(to,false,errno.ETIMEDOUT) end
  
  sock:connect(addr)
  local okay,err1 = coroutine.yield()
  
  if to then nfl.timeout(0) end
  
  if not okay then
    nfl.SOCKETS:remove(sock)
    sock:close()
    syslog('error',"sock:connect(%s) = %s",tostring(addr),errno[err1])
    return nil
  end
  return ios
end

-- **********************************************************************
-- Usage:       ios = tcp.connect(host,port[,to])
-- Desc:        Connect to a remote host
-- Input:       host (string) IP address
--              port (string number) port to connect to
--              to (number/optioal) timeout the operation after to seconds
-- Return:      ios (table) Input/Output object (nil on error)
-- **********************************************************************

function connect(host,port,to)
  local addr = net.address2(host,'any','tcp',port)
  if addr then
    return connecta(addr[1],to)
  end
end

-- **********************************************************************

if _VERSION >= "Lua 5.2" then
  return _ENV -- luacheck: ignore
end
