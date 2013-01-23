/**
 *  Copyright 2011 Zuse Institute Berlin
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

import java.util.EnumMap;
import java.util.Random;
import java.util.regex.Matcher;
import java.util.regex.Pattern;


/**
 * @author Nico Kruber, kruber@zib.de
 *
 */
public class Options {
    
    private final static Options instance = new Options();
    protected static final Pattern CONFIG_SINGLE_OPTIMISATION = Pattern.compile("([a-zA-Z_0-9]*):([a-zA-Z_0-9]*)(?:\\(([a-zA-Z_0-9,]*)\\))?");

    /**
     * The name of the server (part of the URL), e.g. <tt>en.wikipedia.org</tt>.
     */
    public String SERVERNAME = "localhost:8080";
    /**
     * The path on the server (part of the URL), e.g. <tt>/wiki</tt>.
     */
    public String SERVERPATH = "/scalaris-wiki/wiki";
    
    /**
     * Whether to support back-links ("what links here?") or not.
     */
    public boolean WIKI_USE_BACKLINKS = true;
    
    /**
     * How often to re-try a "sage page" operation in case of failures, e.g.
     * concurrent edits.
     * 
     * @see #WIKI_SAVEPAGE_RETRY_DELAY
     */
    public int WIKI_SAVEPAGE_RETRIES = 0;
    
    /**
     * How long to wait after a failed "sage page" operation before trying
     * again (in milliseconds).
     * 
     * @see #WIKI_SAVEPAGE_RETRIES
     */
    public int WIKI_SAVEPAGE_RETRY_DELAY = 10;
    
    /**
     * How often to re-create the bloom filter with the existing pages (in
     * seconds). The bloom filter will be disabled if a value less than or equal
     * to 0 is provided.
     */
    public int WIKI_REBUILD_PAGES_CACHE = 10 * 60;
    
    /**
     * How often to re-create the bloom filter with the existing pages (in
     * seconds). The bloom filter will be disabled if a value less than or equal
     * to 0 is provided.
     */
    public STORE_CONTRIB_TYPE WIKI_STORE_CONTRIBUTIONS = STORE_CONTRIB_TYPE.OUTSIDE_TX;
    
    /**
     * Optimisations to use for the different Scalaris operations.
     */
    final public EnumMap<ScalarisOpType, Optimisation> OPTIMISATIONS = new EnumMap<ScalarisOpType, Options.Optimisation>(
            ScalarisOpType.class);
    
    /**
     * Store user requests in a log for the last x minutes before the last
     * request.
     */
    public int LOG_USER_REQS = 0;
    
    /**
     * Time (in seconds) between executions of the node discovery daemon of
     * {@link de.zib.scalaris.NodeDiscovery} to look for new Scalaris nodes (
     * <tt>0</tt> to disable).
     */
    public int SCALARIS_NODE_DISCOVERY = 60;
    
    /**
     * Creates a new default option object.
     */
    public Options() {
        for (ScalarisOpType op : ScalarisOpType.values()) {
            OPTIMISATIONS.put(op, new APPEND_INCREMENT());
        }
    }

    /**
     * Gets the static instance used throughout the wiki implementation.
     * 
     * @return the instance
     */
    public static Options getInstance() {
        return instance;
    }
    
    /**
     * Type of storing user contributions in the DB.
     */
    public static enum STORE_CONTRIB_TYPE {
        /**
         * Do not store user contributions.
         */
        NONE("NONE"),
        /**
         * Store user contributions outside the main transaction used during
         * save.
         */
        OUTSIDE_TX("OUTSIDE_TX");

        private final String text;

        STORE_CONTRIB_TYPE(String text) {
            this.text = text;
        }

        /**
         * Converts the enum to text.
         */
        public String toString() {
            return this.text;
        }

        /**
         * Tries to convert a text to the according enum value.
         * 
         * @param text the text to convert
         * 
         * @return the according enum value
         */
        public static STORE_CONTRIB_TYPE fromString(String text) {
            if (text != null) {
                for (STORE_CONTRIB_TYPE b : STORE_CONTRIB_TYPE.values()) {
                    if (text.equalsIgnoreCase(b.text)) {
                        return b;
                    }
                }
            }
            throw new IllegalArgumentException("No constant with text " + text
                    + " found");
        }
    }
    
    /**
     * Indicates a generic optimisation implementation.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static interface Optimisation {
    }
    
    /**
     * Indicates that the traditional read/write operations of Scalaris should
     * be used, i.e. no append/increment.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static class TRADITIONAL implements Optimisation {
        @Override
        public String toString() {
            return "TRADITIONAL";
        }
    }

    /**
     * Indicates that the new append and increment operations of Scalaris should
     * be used, i.e.
     * {@link de.zib.scalaris.Transaction#addDelOnList(String, java.util.List, java.util.List)}
     * and {@link de.zib.scalaris.Transaction#addOnNr(String, Object)}.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static class APPEND_INCREMENT implements Optimisation {
        @Override
        public String toString() {
            return "APPEND_INCREMENT";
        }
    }

    /**
     * Indicates that the new partial reads for random elements of a list
     * {@link de.zib.scalaris.operations.ReadRandomFromListOp} and sublists
     * {@link de.zib.scalaris.operations.ReadSublistOp} should be used.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static interface IPartialRead {
    }

    /**
     * Indicates that the new append and increment operations of Scalaris should
     * be used, i.e.
     * {@link de.zib.scalaris.Transaction#addDelOnList(String, java.util.List, java.util.List)}
     * and {@link de.zib.scalaris.Transaction#addOnNr(String, Object)} as well
     * as partial reads for random elements of a list
     * {@link de.zib.scalaris.operations.ReadRandomFromListOp} and sublists
     * {@link de.zib.scalaris.operations.ReadSublistOp}.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static class APPEND_INCREMENT_PARTIALREAD extends APPEND_INCREMENT implements IPartialRead {
        @Override
        public String toString() {
            return "APPEND_INCREMENT_PARTIALREAD";
        }
    }

    /**
     * Indicates that the new append and increment operations of Scalaris should
     * be used and list values should be distributed among several partions, i.e.
     * buckets.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static abstract class APPEND_INCREMENT_BUCKETS implements Optimisation {
        final protected int buckets;
        
        /**
         * Constructor.
         * 
         * @param buckets
         *            number of available buckets
         */
        public APPEND_INCREMENT_BUCKETS(int buckets) {
            this.buckets = buckets;
        }

        /**
         * Gets the number of available buckets
         * 
         * @return number of buckets
         */
        public int getBuckets() {
            return buckets;
        }
        
        /**
         * Gets the string to append to the key in order to point to the bucket
         * for the given value.
         * 
         * @param value
         *            the value to check the bucket for
         * 
         * @return the bucket string, e.g. ":0"
         */
        abstract public <T> String getBucketString(final T value);
    }

    /**
     * Indicates that the new append and increment operations of Scalaris should
     * be used and list values should be randomly distributed among several
     * partions, i.e. buckets.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static class APPEND_INCREMENT_BUCKETS_RANDOM extends APPEND_INCREMENT_BUCKETS {
        final static protected Random rand = new Random();
        /**
         * Constructor.
         * 
         * @param buckets
         *            number of available buckets
         */
        public APPEND_INCREMENT_BUCKETS_RANDOM(int buckets) {
            super(buckets);
        }

        /**
         * Gets the string to append to the key in order to point to the bucket
         * for the given value.
         * 
         * @param value
         *            the value to check the bucket for
         * 
         * @return the bucket string, e.g. ":0"
         */
        @Override
        public <T> String getBucketString(final T value) {
            if (buckets > 1) {
                return ":" + rand.nextInt(buckets);
            } else {
                return "";
            }
        }
        
        @Override
        public String toString() {
            return "APPEND_INCREMENT_BUCKETS_RANDOM(" + buckets + ")";
        }
    }

    /**
     * Indicates that the new append and increment operations of Scalaris should
     * be used and list values should be distributed among several partions, i.e.
     * buckets, depending on the value's hash.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    public static class APPEND_INCREMENT_BUCKETS_WITH_HASH extends APPEND_INCREMENT_BUCKETS {
        /**
         * Constructor.
         * 
         * @param buckets
         *            number of available buckets
         */
        public APPEND_INCREMENT_BUCKETS_WITH_HASH(int buckets) {
            super(buckets);
        }
        
        /**
         * Gets the string to append to the key in order to point to the bucket
         * for the given value.
         * 
         * @param value
         *            the value to check the bucket for
         * 
         * @return the bucket string, e.g. ":0"
         */
        @Override
        public <T> String getBucketString(final T value) {
            if (buckets > 1) {
                return ":" + Math.abs((value.hashCode() % buckets));
            } else {
                return "";
            }
        }
        
        @Override
        public String toString() {
            return "APPEND_INCREMENT_BUCKETS_WITH_HASH(" + buckets + ")";
        }
    }
    
    /**
     * Parses the given option strings into their appropriate properties.
     * 
     * @param options
     *            the {@link Options} object to parse into
     * @param SERVERNAME
     *            {@link Options#SERVERNAME}
     * @param SERVERPATH
     *            {@link Options#SERVERPATH}
     * @param WIKI_USE_BACKLINKS
     *            {@link Options#WIKI_USE_BACKLINKS}
     * @param WIKI_SAVEPAGE_RETRIES
     *            {@link Options#WIKI_SAVEPAGE_RETRIES}
     * @param WIKI_SAVEPAGE_RETRY_DELAY
     *            {@link Options#WIKI_SAVEPAGE_RETRY_DELAY}
     * @param WIKI_REBUILD_PAGES_CACHE
     *            {@link Options#WIKI_REBUILD_PAGES_CACHE}
     * @param WIKI_STORE_CONTRIBUTIONS
     *            {@link Options#WIKI_STORE_CONTRIBUTIONS}
     * @param OPTIMISATIONS
     *            {@link Options#OPTIMISATIONS}
     * @param LOG_USER_REQS
     *            {@link Options#LOG_USER_REQS}
     * @param SCALARIS_NODE_DISCOVERY
     *            {@link Options#SCALARIS_NODE_DISCOVERY}
     */
    public static void parseOptions(Options options, final String SERVERNAME, final String SERVERPATH,
            final String WIKI_USE_BACKLINKS,
            final String WIKI_SAVEPAGE_RETRIES,
            final String WIKI_SAVEPAGE_RETRY_DELAY,
            final String WIKI_REBUILD_PAGES_CACHE,
            final String WIKI_STORE_CONTRIBUTIONS, final String OPTIMISATIONS,
            final String LOG_USER_REQS, final String SCALARIS_NODE_DISCOVERY) {
        if (SERVERNAME != null) {
            options.SERVERNAME = SERVERNAME;
        }
        if (SERVERPATH != null) {
            options.SERVERPATH = SERVERPATH;
        }
        if (WIKI_USE_BACKLINKS != null) {
            options.WIKI_USE_BACKLINKS = Boolean.parseBoolean(WIKI_USE_BACKLINKS);
        }
        if (WIKI_SAVEPAGE_RETRIES != null) {
            options.WIKI_SAVEPAGE_RETRIES = Integer.parseInt(WIKI_SAVEPAGE_RETRIES);
        }
        if (WIKI_SAVEPAGE_RETRY_DELAY != null) {
            options.WIKI_SAVEPAGE_RETRY_DELAY = Integer.parseInt(WIKI_SAVEPAGE_RETRY_DELAY);
        }
        if (WIKI_REBUILD_PAGES_CACHE != null) {
            options.WIKI_REBUILD_PAGES_CACHE = Integer.parseInt(WIKI_REBUILD_PAGES_CACHE);
        }
        if (WIKI_STORE_CONTRIBUTIONS != null) {
            options.WIKI_STORE_CONTRIBUTIONS = STORE_CONTRIB_TYPE.fromString(WIKI_STORE_CONTRIBUTIONS);
        }
        if (OPTIMISATIONS != null) {
            for (String singleOpt : OPTIMISATIONS.split("\\|")) {
                final Matcher matcher = CONFIG_SINGLE_OPTIMISATION.matcher(singleOpt);
                if (matcher.matches()) {
                    final String operationStr = matcher.group(1);
                    if (operationStr.equals("ALL")) {
                        Optimisation optimisation = parseOptimisationString(matcher);
                        if (optimisation == null) {
                            // fall back if not parsed correctly:
                            optimisation = new APPEND_INCREMENT();
                        }
                        for (ScalarisOpType op : ScalarisOpType.values()) {
                            options.OPTIMISATIONS.put(op, optimisation);
                        }
                    } else {
                        ScalarisOpType operation = ScalarisOpType.fromString(operationStr);
                        Optimisation optimisation = parseOptimisationString(matcher);
                        if (optimisation != null) {
                            options.OPTIMISATIONS.put(operation, optimisation);
                        }
                    }
                }
            }
        }
        if (LOG_USER_REQS != null) {
            options.LOG_USER_REQS = Integer.parseInt(LOG_USER_REQS);
        }
        if (SCALARIS_NODE_DISCOVERY != null) {
            options.SCALARIS_NODE_DISCOVERY = Integer.parseInt(SCALARIS_NODE_DISCOVERY);
        }
    }

    /**
     * Parses an optimisation string into an {@link Optimisation} object.
     * 
     * @param matcher
     *            matcher (1st group: group of keys to apply to, 2nd group:
     *            optimisation class, 3rd group: optimisation parameters
     * 
     * @return an {@link Optimisation} implementation or <tt>null</tt> if no
     *         matching optimisation was found
     * @throws NumberFormatException
     *             if an integer parameter was wrong
     */
    public static Optimisation parseOptimisationString(final Matcher matcher)
            throws NumberFormatException {
        String optimisationStr = matcher.group(2);
        String parameterStr = matcher.group(3);
        Optimisation optimisation = null;
        if (optimisationStr.equals("TRADITIONAL") && parameterStr == null) {
            optimisation = new Options.TRADITIONAL();
        } else if (optimisationStr.equals("APPEND_INCREMENT") && parameterStr == null) {
            optimisation = new Options.APPEND_INCREMENT();
        } else if (optimisationStr.equals("APPEND_INCREMENT_PARTIALREAD") && parameterStr == null) {
            optimisation = new Options.APPEND_INCREMENT_PARTIALREAD();
        } else if (optimisationStr.equals("APPEND_INCREMENT_BUCKETS_RANDOM") && parameterStr != null) {
            String[] parameters = parameterStr.split(",");
            optimisation = new Options.APPEND_INCREMENT_BUCKETS_RANDOM(Integer.parseInt(parameters[0]));
        } else if (optimisationStr.equals("APPEND_INCREMENT_BUCKETS_WITH_HASH") && parameterStr != null) {
            String[] parameters = parameterStr.split(",");
            optimisation = new Options.APPEND_INCREMENT_BUCKETS_WITH_HASH(Integer.parseInt(parameters[0]));
        } else {
            System.err.println("unknown optimisation found: " + matcher.group());
        }
        return optimisation;
    }
}
