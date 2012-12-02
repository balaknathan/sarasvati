/*
    This file is part of Sarasvati.

    Sarasvati is free software: you can redistribute it and/or modify
    it under the terms of the GNU Lesser General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    Sarasvati is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with Sarasvati.  If not, see <http://www.gnu.org/licenses/>.

    Copyright 2009 Paul Lorenz
*/
package com.googlecode.sarasvati.env;

/**
 * Attribute converter for String <--> Float
 *
 * @author Paul Lorenz
 */
public final class FloatAttributeConverter extends AbstractStringValueOfAttributeConverter
{
  /**
   * Converts the given string to a Float
   *
   * @see com.googlecode.sarasvati.env.AttributeConverter#stringToObject(java.lang.String, java.lang.Class)
   */
  @Override
  public Object stringToObject (final String string, final Class<?> object)
  {
    return Float.valueOf( string );
  }
}