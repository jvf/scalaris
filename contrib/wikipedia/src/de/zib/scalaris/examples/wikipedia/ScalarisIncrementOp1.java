/**
 *  Copyright 2012 Zuse Institute Berlin
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */
package de.zib.scalaris.examples.wikipedia;

import java.math.BigInteger;
import java.security.InvalidParameterException;

import com.ericsson.otp.erlang.OtpErlangException;

import de.zib.scalaris.NotFoundException;
import de.zib.scalaris.Transaction.RequestList;
import de.zib.scalaris.Transaction.ResultList;
import de.zib.scalaris.UnknownException;

/**
 * Implements an increment operation using the read and write operations of
 * Scalaris.
 * 
 * @param <T> the type of the value to write
 * 
 * @author Nico Kruber, kruber@zib.de
 */
public class ScalarisIncrementOp1<T extends Number> implements
        ScalarisOp<RequestList, ResultList> {
    final protected String key;
    final protected BigInteger value;
    
    /**
     * Creates a write operation.
     * 
     * @param key
     *            the key to write to
     * @param value
     *            the value to write
     */
    public ScalarisIncrementOp1(String key, T value) {
        this.key = key;
        if (value instanceof Integer) {
            this.value = BigInteger.valueOf((Integer) value);
        } else if (value instanceof Long) {
            this.value = BigInteger.valueOf((Long) value);
        } else if (value instanceof BigInteger) {
            this.value = (BigInteger) value;
        } else {
            throw new InvalidParameterException("Type not supported for increment: " + value.getClass().toString());
        }
    }

    @Override
    public int workPhases() {
        return 2;
    }

    @Override
    public final int doPhase(int phase, int firstOp, ResultList results,
            RequestList requests) throws OtpErlangException, UnknownException,
            IllegalArgumentException {
        switch (phase) {
        case 0: return prepareRead(requests);
        case 1: return prepareWrite(firstOp, results, requests);
        case 2: return checkWrite(firstOp, results);
        default:
            throw new IllegalArgumentException("No phase " + phase);
        }
    }
    
    /**
     * Adds a read operation for the current value to the request list.
     * 
     * @param requests the request list
     * 
     * @return <tt>0</tt> (no operation processed since no results are used)
     */
    protected int prepareRead(RequestList requests) {
        requests.addRead(key);
        return 0;
    }

    /**
     * Verifies the read operation, increments the number and adds a write
     * operation to the request list.
     * 
     * @param firstOp
     *            the first operation to process inside the result list
     * @param results
     *            the result list
     * @param requests
     *            the request list
     * 
     * @return <tt>1</tt> operation processed (the read)
     */
    protected int prepareWrite(final int firstOp, final ResultList results,
            final RequestList requests) throws OtpErlangException,
            UnknownException {
        BigInteger currrentValue;
        try {
            currrentValue = results.processReadAt(firstOp).bigIntValue();
        } catch (NotFoundException e) {
            // this is ok
            currrentValue = BigInteger.ZERO;
        }
        currrentValue.add(value);
        requests.addWrite(key, currrentValue);
        return 1;
    }

    /**
     * Verifies the write operation.
     * 
     * @param firstOp   the first operation to process inside the result list
     * @param results   the result list
     * 
     * @return <tt>1</tt> operation processed (the write)
     */
    protected int checkWrite(final int firstOp, final ResultList results)
            throws OtpErlangException, UnknownException {
        results.processWriteAt(firstOp);
        return 1;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.ScalarisOp#toString()
     */
    @Override
    public String toString() {
        return "Scalaris.increment(" + key + ", " + value + ")";
    }

}
